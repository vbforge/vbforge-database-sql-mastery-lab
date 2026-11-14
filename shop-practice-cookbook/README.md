# CodeShop: a MySQL practice database for Java developers

A small online shop, modelled the way you would model it in a real Spring Boot project. It has enough relationships, constraints and awkward data to practise everything from `SELECT` to transactions and index tuning.

**Files**

| File | What it is |
|---|---|
| `shop_practice.sql` | One script: schema, seed data, views, function, procedure, triggers |
| `sql_cookbook.html` | Searchable page of 125 queries with copy buttons, grouped by topic |
| `README.md` | This file |

**Requirements:** MySQL 8.0.16 or newer (CHECK constraints are enforced from this version). Tested target: Workbench on `localhost:3306`.

## 1. Install

1. Open MySQL Workbench and connect to your local server.
2. `File > Open SQL Script...` and pick `shop_practice.sql` (or paste it into a new tab).
3. Run the whole script with the lightning bolt. It takes a few seconds.
4. The last result grid lists row counts per table. If you see it, the install worked.

The script begins with `DROP DATABASE IF EXISTS shop_practice`, so you can re-run it any time to get a clean reset. All dates are relative to `NOW()`, which means "last 30 days" queries always return data.

> **Safe updates:** Workbench refuses `UPDATE`/`DELETE` without a key in the `WHERE` clause (error 1175). The script turns this off while seeding and turns it back on at the end. If you want to experiment with bulk updates, run `SET SQL_SAFE_UPDATES = 0;` in your tab.

## 2. The domain

```
users ──< addresses
  │
  ├──< user_roles >── roles
  │
  ├──< orders ──< order_items >── products >── categories (tree)
  │       │                           │
  │       ├──< payments               ├──< product_tags >── tags
  │       └──< order_status_history   ├──< reviews >── users
  │                                   └──< price_audit
```

| Table | Rows | What it teaches |
|---|---|---|
| `users` | 210 | Unique email, ENUM status, soft delete (`deleted_at`), nullable columns, Cyrillic names |
| `roles`, `user_roles` | 4 / ~210 | Many-to-many with a composite primary key |
| `addresses` | ~280 | One-to-many, one default address per user |
| `categories` | 16 | Self-referencing tree, 3 levels, recursive CTEs |
| `products` | 60 | DECIMAL prices, stock, JSON `attributes`, FULLTEXT index, CHECK constraints |
| `tags`, `product_tags` | 7 / ~100 | Second many-to-many |
| `orders` | 1,200 | Status lifecycle, denormalized total, `version` column for optimistic locking |
| `order_items` | 3,720 | Price snapshot (`unit_price`), unique `(order_id, product_id)` |
| `payments` | ~1,200 | Several attempts per order (FAILED then SUCCESS), refunds |
| `reviews` | ~450 | One review per user and product, rating CHECK 1-5, nullable text |
| `order_status_history` | ~3,500 | Audit trail, filled by trigger, good for `LAG()` |
| `price_audit` | 6 | Filled by trigger when a price changes |

The exact counts are printed by the last query of the script.

## 3. Edge cases that are seeded on purpose

| Situation | Where to find it | Practise with |
|---|---|---|
| Users who never ordered (about 56 generated users, plus a few hand-made ones) | `users` without rows in `orders` | `LEFT JOIN ... IS NULL`, `NOT EXISTS` |
| Heavy buyers vs. occasional buyers | users 1 to 20 have far more orders | `GROUP BY`, `HAVING`, `RANK()` |
| Soft-deleted users (every 25th) | `deleted_at IS NOT NULL`, some still have orders | Filtering, `@SQLRestriction` |
| NULL phone, birth date, description, review text | many tables | `IS NULL`, `COALESCE`, `COUNT(*)` vs `COUNT(col)` |
| Three different people named John Smith | `users` ids 203 to 205 | Grouping by name vs. by id, why name is not a key |
| Cyrillic names, `+` in an email | `users` ids 201, 202, 206 | utf8mb4, `LIKE`, `COLLATE` |
| Price ties (19.99, 29.99, 49.99, 59.99, 249.00 ...) | `products` | `RANK` vs. `DENSE_RANK` vs. `ROW_NUMBER` |
| Out of stock but best seller (id 5) | `products` | Stock checks, `FOR UPDATE` |
| Inactive products that have sales history (14, 25) | `products` | Filters on `active`, joins to history |
| Products that were never ordered (57 to 60) | `products` | Anti-joins |
| Empty category (Gift Cards) | `categories` | `LEFT JOIN`, tree queries |
| Stale orders stuck in `NEW` | `orders` | Date arithmetic, cleanup queries |
| Orders with a failed payment before the successful one | `payments` | Aggregation without double counting |
| Refunded and cancelled orders | `orders`, `payments` | Conditional aggregation |
| Order price differs from the current product price | `order_items` vs. `products` | Why you snapshot prices |
| JSON attributes on electronics only | `products.attributes` | `->>`, `JSON_CONTAINS`, `JSON_TABLE` |
| Ties in customer spend, empty months | aggregates | Window functions, gap handling |

## 4. Routines

| Object | Type | Purpose |
|---|---|---|
| `v_order_summary` | View | One row per order with customer, item count and paid amount |
| `v_product_stats` | View | Units sold, revenue, review count and average rating per product |
| `fn_user_lifetime_value(user_id)` | Function | Sum of paid, shipped and delivered orders |
| `sp_place_order(...)` | Procedure | Transaction with row lock, stock check, rollback on error |
| `trg_products_price_audit` | Trigger | Writes `price_audit` on price change |
| `trg_orders_history_insert/update` | Triggers | Write `order_status_history` |

## 5. Suggested practice path

1. **Read:** filters, sorting, pagination, `NULL` handling (cookbook sections 1 and 2).
2. **Join and aggregate:** all join types, `GROUP BY`, `HAVING`, conditional aggregation.
3. **Advanced reads:** subqueries, CTEs, window functions, recursive tree queries.
4. **Write:** insert, upsert, update with join, delete, and provoke each constraint error on purpose.
5. **Transactions:** open two Workbench tabs and try locking, `SKIP LOCKED`, optimistic locking and a deadlock.
6. **Performance:** `EXPLAIN`, add an index on `products.name`, compare plans, break an index with a function call.
7. **Java side:** see the next section.

## 6. Connecting a Spring Boot app (next step)

Not generated yet. Say the word and I will build a runnable Maven project for it. This is how the schema maps to Java:

**Connection**

```properties
spring.datasource.url=jdbc:mysql://localhost:3306/shop_practice?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
spring.datasource.username=root
spring.datasource.password=<your password>
spring.jpa.hibernate.ddl-auto=validate
```

Dependencies: `spring-boot-starter-data-jpa`, `spring-boot-starter-web`, `mysql-connector-j`.

**Type mapping**

| SQL | Java |
|---|---|
| `BIGINT` | `Long` |
| `DECIMAL` | `BigDecimal` (never `double` for money) |
| `DATETIME` | `LocalDateTime` |
| `ENUM` | Java `enum` with `@Enumerated(EnumType.STRING)` |
| `JSON` | `@JdbcTypeCode(SqlTypes.JSON)` on a `Map<String,Object>` or a record |
| `TINYINT(1)` | `boolean` |

**Mapping notes by table**

- `orders.version` is the `@Version` field. Two concurrent edits trigger `ObjectOptimisticLockingFailureException`.
- `users.deleted_at` fits `@SQLRestriction("deleted_at IS NULL")` for soft delete.
- `user_roles` and `product_tags` are plain `@ManyToMany` with `@JoinTable`.
- `categories.parent_id` is a self-referencing `@ManyToOne` parent with a `@OneToMany` children list.
- `order_items` is a real entity (it has quantity and price), not a `@ManyToMany`.
- The views map well to read-only `@Immutable` entities or interface projections.
- `sp_place_order` is called with `@Procedure` or `StoredProcedureQuery`.

**Scenarios the app would cover**

1. Repository methods and their SQL (`findByEmail`, `findByStatusOrderByCreatedAtDesc`, `Pageable`).
2. The N+1 problem and fixes (`@EntityGraph`, `JOIN FETCH`, batch fetching).
3. DTO projections vs. loading full entities.
4. `@Transactional` rollback rules, isolation levels, read-only transactions.
5. Optimistic and pessimistic locking (`@Lock(PESSIMISTIC_WRITE)` maps to `FOR UPDATE`).
6. Native queries, specifications and the criteria API.
7. Mapping constraint violations to `DataIntegrityViolationException`.
8. Batch inserts, `rewriteBatchedStatements=true`, and the `IDENTITY` limitation.
9. Integration tests with Testcontainers MySQL.

## 7. Resetting and cleaning up

- Reset to the initial state: run `shop_practice.sql` again.
- Remove everything: `DROP DATABASE shop_practice;`
