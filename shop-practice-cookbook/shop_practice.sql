-- =====================================================================
--  shop_practice.sql  -  "CodeShop" practice database for MySQL 8.0+
-- =====================================================================
--  HOW TO RUN (MySQL Workbench, localhost:3306)
--    1. File > Open SQL Script (or paste this whole file into a new tab)
--    2. Click the lightning bolt (Execute all). Takes a few seconds.
--    3. The last result grid shows row counts per table.
--
--  WARNING: the script starts with DROP DATABASE IF EXISTS shop_practice.
--           Re-running it resets everything to a clean, identical state
--           (dates are relative to NOW(), so "last 30 days" always has data).
--
--  DOMAIN: an online shop (electronics, books, home, sports).
--    users --< addresses
--    users >--< roles                (user_roles)
--    categories (self-referencing tree) --< products >--< tags (product_tags)
--    users --< orders --< order_items >-- products
--    orders --< payments             (several attempts per order possible)
--    orders --< order_status_history (audit trail, filled by trigger)
--    users, products --< reviews     (one review per user+product)
--    products --< price_audit        (filled by trigger)
--
--  Routines: v_order_summary, v_product_stats (views), fn_user_lifetime_value
--            (function), sp_place_order (stored procedure with transaction),
--            triggers on products and orders.
-- =====================================================================

SET NAMES utf8mb4;
SET SQL_SAFE_UPDATES = 0;   -- Workbench enables "safe updates" by default; seeds need UPDATE without key.

DROP DATABASE IF EXISTS shop_practice;
CREATE DATABASE shop_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE shop_practice;

-- =====================================================================
--  1. SCHEMA
-- =====================================================================

CREATE TABLE users (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  email       VARCHAR(255) NOT NULL,
  first_name  VARCHAR(100) NOT NULL,
  last_name   VARCHAR(100) NOT NULL,
  phone       VARCHAR(30)  NULL,
  birth_date  DATE         NULL,
  status      ENUM('ACTIVE','PENDING','SUSPENDED') NOT NULL DEFAULT 'ACTIVE',
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  deleted_at  DATETIME     NULL,                      -- soft delete marker
  PRIMARY KEY (id),
  UNIQUE KEY uk_users_email (email),
  KEY idx_users_last_name (last_name),
  KEY idx_users_status_created (status, created_at)
) ENGINE=InnoDB;

CREATE TABLE roles (
  id    INT         NOT NULL AUTO_INCREMENT,
  name  VARCHAR(30) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_roles_name (name)
) ENGINE=InnoDB;

CREATE TABLE user_roles (                              -- many-to-many users <-> roles
  user_id    BIGINT   NOT NULL,
  role_id    INT      NOT NULL,
  granted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, role_id),
  KEY idx_user_roles_role (role_id),
  CONSTRAINT fk_user_roles_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_user_roles_role FOREIGN KEY (role_id) REFERENCES roles (id)
) ENGINE=InnoDB;

CREATE TABLE addresses (
  id           BIGINT       NOT NULL AUTO_INCREMENT,
  user_id      BIGINT       NOT NULL,
  line1        VARCHAR(200) NOT NULL,
  city         VARCHAR(100) NOT NULL,
  postal_code  VARCHAR(20)  NULL,
  country_code CHAR(2)      NOT NULL,
  is_default   TINYINT(1)   NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  KEY idx_addresses_user (user_id),
  KEY idx_addresses_country_city (country_code, city),
  CONSTRAINT fk_addresses_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE categories (                              -- self-referencing tree
  id         INT          NOT NULL AUTO_INCREMENT,
  name       VARCHAR(100) NOT NULL,
  slug       VARCHAR(100) NOT NULL,
  parent_id  INT          NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_categories_slug (slug),
  KEY idx_categories_parent (parent_id),
  CONSTRAINT fk_categories_parent FOREIGN KEY (parent_id) REFERENCES categories (id)
) ENGINE=InnoDB;

CREATE TABLE products (
  id              BIGINT         NOT NULL AUTO_INCREMENT,
  sku             VARCHAR(30)    NOT NULL,
  name            VARCHAR(200)   NOT NULL,              -- deliberately NOT indexed (see cookbook: EXPLAIN)
  description     TEXT           NULL,
  category_id     INT            NOT NULL,
  price           DECIMAL(10,2)  NOT NULL,
  stock_quantity  INT            NOT NULL DEFAULT 0,
  active          TINYINT(1)     NOT NULL DEFAULT 1,
  attributes      JSON           NULL,
  created_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at      DATETIME       NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_products_sku (sku),
  KEY idx_products_category (category_id),
  KEY idx_products_price (price),
  FULLTEXT KEY ft_products_text (name, description),
  CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories (id),
  CONSTRAINT chk_products_price CHECK (price >= 0),
  CONSTRAINT chk_products_stock CHECK (stock_quantity >= 0)
) ENGINE=InnoDB;

CREATE TABLE tags (
  id    INT         NOT NULL AUTO_INCREMENT,
  name  VARCHAR(50) NOT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uk_tags_name (name)
) ENGINE=InnoDB;

CREATE TABLE product_tags (                            -- many-to-many products <-> tags
  product_id BIGINT NOT NULL,
  tag_id     INT    NOT NULL,
  PRIMARY KEY (product_id, tag_id),
  KEY idx_product_tags_tag (tag_id),
  CONSTRAINT fk_product_tags_product FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE,
  CONSTRAINT fk_product_tags_tag     FOREIGN KEY (tag_id)     REFERENCES tags (id)     ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE orders (
  id                   BIGINT        NOT NULL AUTO_INCREMENT,
  user_id              BIGINT        NOT NULL,
  shipping_address_id  BIGINT        NOT NULL,
  status               ENUM('NEW','PAID','SHIPPED','DELIVERED','CANCELLED','REFUNDED') NOT NULL DEFAULT 'NEW',
  total_amount         DECIMAL(12,2) NOT NULL DEFAULT 0,   -- denormalized on purpose
  version              INT           NOT NULL DEFAULT 0,   -- for optimistic locking (@Version)
  created_at           DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at           DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  shipped_at           DATETIME      NULL,
  delivered_at         DATETIME      NULL,
  PRIMARY KEY (id),
  KEY idx_orders_user (user_id),
  KEY idx_orders_address (shipping_address_id),
  KEY idx_orders_status_created (status, created_at),
  KEY idx_orders_created (created_at),
  CONSTRAINT fk_orders_user    FOREIGN KEY (user_id)             REFERENCES users (id),
  CONSTRAINT fk_orders_address FOREIGN KEY (shipping_address_id) REFERENCES addresses (id),
  CONSTRAINT chk_orders_total CHECK (total_amount >= 0)
) ENGINE=InnoDB;

CREATE TABLE order_items (
  id          BIGINT        NOT NULL AUTO_INCREMENT,
  order_id    BIGINT        NOT NULL,
  product_id  BIGINT        NOT NULL,
  quantity    INT           NOT NULL,
  unit_price  DECIMAL(10,2) NOT NULL,                   -- price snapshot at purchase time
  PRIMARY KEY (id),
  UNIQUE KEY uk_order_items_order_product (order_id, product_id),
  KEY idx_order_items_product (product_id),
  CONSTRAINT fk_order_items_order   FOREIGN KEY (order_id)   REFERENCES orders (id) ON DELETE CASCADE,
  CONSTRAINT fk_order_items_product FOREIGN KEY (product_id) REFERENCES products (id),
  CONSTRAINT chk_order_items_qty   CHECK (quantity > 0),
  CONSTRAINT chk_order_items_price CHECK (unit_price >= 0)
) ENGINE=InnoDB;

CREATE TABLE payments (
  id            BIGINT        NOT NULL AUTO_INCREMENT,
  order_id      BIGINT        NOT NULL,
  amount        DECIMAL(12,2) NOT NULL,
  method        ENUM('CARD','PAYPAL','BANK_TRANSFER') NOT NULL,
  status        ENUM('PENDING','SUCCESS','FAILED','REFUNDED') NOT NULL,
  external_ref  VARCHAR(40)   NULL,
  created_at    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_payments_external_ref (external_ref),
  KEY idx_payments_order (order_id),
  KEY idx_payments_status_created (status, created_at),
  CONSTRAINT fk_payments_order FOREIGN KEY (order_id) REFERENCES orders (id),
  CONSTRAINT chk_payments_amount CHECK (amount >= 0)
) ENGINE=InnoDB;

CREATE TABLE reviews (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  user_id     BIGINT       NOT NULL,
  product_id  BIGINT       NOT NULL,
  rating      TINYINT      NOT NULL,
  title       VARCHAR(150) NULL,
  body        TEXT         NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uk_reviews_user_product (user_id, product_id),
  KEY idx_reviews_product (product_id),
  CONSTRAINT fk_reviews_user    FOREIGN KEY (user_id)    REFERENCES users (id),
  CONSTRAINT fk_reviews_product FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE,
  CONSTRAINT chk_reviews_rating CHECK (rating BETWEEN 1 AND 5)
) ENGINE=InnoDB;

CREATE TABLE order_status_history (
  id          BIGINT      NOT NULL AUTO_INCREMENT,
  order_id    BIGINT      NOT NULL,
  old_status  VARCHAR(20) NULL,
  new_status  VARCHAR(20) NOT NULL,
  changed_at  DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_osh_order_changed (order_id, changed_at),
  CONSTRAINT fk_osh_order FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE price_audit (
  id          BIGINT        NOT NULL AUTO_INCREMENT,
  product_id  BIGINT        NOT NULL,
  old_price   DECIMAL(10,2) NOT NULL,
  new_price   DECIMAL(10,2) NOT NULL,
  changed_at  DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_price_audit_product (product_id, changed_at),
  CONSTRAINT fk_price_audit_product FOREIGN KEY (product_id) REFERENCES products (id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- =====================================================================
--  2. HELPER NUMBER TABLE (dropped at the end of the script)
--     seq.n = 0 .. 9999, used to generate rows without recursive CTEs
-- =====================================================================

CREATE TABLE digits (d INT NOT NULL PRIMARY KEY);
INSERT INTO digits (d) VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

CREATE TABLE seq (n INT NOT NULL PRIMARY KEY);
INSERT INTO seq (n)
SELECT a.d + b.d * 10 + c.d * 100 + e.d * 1000
FROM digits a, digits b, digits c, digits e;

-- =====================================================================
--  3. REFERENCE DATA
-- =====================================================================

INSERT INTO roles (name) VALUES ('ADMIN'), ('MANAGER'), ('SUPPORT'), ('CUSTOMER');

INSERT INTO tags (name) VALUES ('bestseller'), ('new'), ('sale'), ('eco'), ('gift'), ('premium'), ('bundle');

-- Category tree (3 levels). "Gift Cards" is an EMPTY category on purpose.
INSERT INTO categories (id, name, slug, parent_id) VALUES
  (1,  'Electronics',      'electronics',      NULL),
  (2,  'Laptops',          'laptops',          1),
  (3,  'Smartphones',      'smartphones',      1),
  (4,  'Accessories',      'accessories',      1),
  (5,  'Keyboards & Mice', 'keyboards-mice',   4),
  (6,  'Headphones',       'headphones',       4),
  (7,  'Books',            'books',            NULL),
  (8,  'Programming',      'programming',      7),
  (9,  'Fiction',          'fiction',          7),
  (10, 'Home',             'home',             NULL),
  (11, 'Kitchen',          'kitchen',          10),
  (12, 'Office Furniture', 'office-furniture', 10),
  (13, 'Sports',           'sports',           NULL),
  (14, 'Outdoor',          'outdoor',          13),
  (15, 'Fitness',          'fitness',          13),
  (16, 'Gift Cards',       'gift-cards',       NULL);

-- Products. Notes on the data:
--   * ids 1-6 are the "hot" sellers (laptops/phones); id 5 is hot but OUT OF STOCK
--   * many price ties (19.99, 29.99, 34.99, 39.99, 44.99, 49.99, 59.99, 249.00 ...) for RANK vs DENSE_RANK
--   * ids 14 and 25 are inactive but have sales history
--   * ids 57-60 are NEVER ordered (57-59 inactive, 60 active but unsold)
INSERT INTO products (id, sku, name, category_id, price, stock_quantity, active) VALUES
  (1,  'LT-1001', 'Aero Book 13',                   2,  1099.00,  40, 1),
  (2,  'LT-1002', 'Nova Pro 15',                    2,  1499.00,  18, 1),
  (3,  'LT-1003', 'Orion Gaming 17',                2,  1899.00,   7, 1),
  (4,  'PH-2001', 'Pixelon X',                      3,   899.00,  55, 1),
  (5,  'PH-2002', 'Galaxia S',                      3,   799.00,   0, 1),
  (6,  'PH-2003', 'Nordic Phone 5',                 3,   499.00, 120, 1),
  (7,  'KB-3001', 'Mechanical Keyboard K1',         5,    89.99,  80, 1),
  (8,  'KB-3002', 'Wireless Keyboard W2',           5,    59.99,  60, 1),
  (9,  'KB-3003', 'Ergonomic Mouse M3',             5,    49.99, 100, 1),
  (10, 'KB-3004', 'Gaming Mouse G7',                5,    59.99,  45, 1),
  (11, 'KB-3005', 'Mouse Pad XL',                   5,    19.99, 200, 1),
  (12, 'HP-4001', 'Noise-Cancelling Headphones N5', 6,   249.00,  30, 1),
  (13, 'HP-4002', 'Wireless Earbuds E2',            6,   129.00,  75, 1),
  (14, 'HP-4003', 'Studio Headphones S1',           6,   179.00,  20, 0),
  (15, 'HP-4004', 'Budget Earbuds B1',              6,    19.99, 300, 1),
  (16, 'AC-5001', 'USB-C Hub 7-in-1',               4,    39.99, 150, 1),
  (17, 'AC-5002', 'Laptop Stand Aluminium',         4,    34.99,  90, 1),
  (18, 'AC-5003', 'Webcam 1080p',                   4,    69.99,  50, 1),
  (19, 'AC-5004', 'Portable SSD 1TB',               4,   109.00,  65, 1),
  (20, 'AC-5005', 'Phone Case Universal',           4,    14.99, 400, 1),
  (21, 'BK-6001', 'Java Streams Handbook',          8,    39.99,  55, 1),
  (22, 'BK-6002', 'Spring Boot Recipes',            8,    44.99,  48, 1),
  (23, 'BK-6003', 'SQL for Application Developers', 8,    34.99,  90, 1),
  (24, 'BK-6004', 'Hibernate Performance Guide',    8,    49.99,  35, 1),
  (25, 'BK-6005', 'Microservices Field Guide',      8,    54.99,  25, 0),
  (26, 'BK-6006', 'Kafka in Practice',              8,    49.99,  12, 1),
  (27, 'BK-7001', 'The Last Compiler',              9,    14.99, 150, 1),
  (28, 'BK-7002', 'Midnight in Kyiv',               9,    17.99,  90, 1),
  (29, 'BK-7003', 'Carpathian Tales',               9,    12.99, 100, 1),
  (30, 'BK-7004', 'Space Opera Vol. 1',             9,     9.99, 200, 1),
  (31, 'KT-8001', 'Burr Coffee Grinder',           11,    59.99,  40, 1),
  (32, 'KT-8002', 'Compact Espresso Machine',      11,   249.00,  15, 1),
  (33, 'KT-8003', 'Chef Knife 8 inch',             11,    39.99,  70, 1),
  (34, 'KT-8004', 'Non-stick Pan 28cm',            11,    29.99,  85, 1),
  (35, 'KT-8005', 'Electric Kettle 1.7L',          11,    34.99, 110, 1),
  (36, 'KT-8006', 'Cast Iron Skillet',             11,    29.99,  60, 1),
  (37, 'OF-9001', 'Standing Desk 140cm',           12,   449.00,  12, 1),
  (38, 'OF-9002', 'Ergonomic Chair Pro',           12,   329.00,   9, 1),
  (39, 'OF-9003', 'Dual Monitor Arm',              12,    79.99,  40, 1),
  (40, 'OF-9004', 'LED Desk Lamp',                 12,    29.99, 120, 1),
  (41, 'OF-9005', 'Cable Management Kit',          12,    12.99, 250, 1),
  (42, 'OD-1001', 'Hiking Backpack 40L',           14,    89.00,  35, 1),
  (43, 'OD-1002', 'Trekking Poles Pair',           14,    44.99,  50, 1),
  (44, 'OD-1003', 'Camping Tent 2P',               14,   159.00,  14, 1),
  (45, 'OD-1004', 'Sleeping Bag -5C',              14,    99.00,  22, 1),
  (46, 'OD-1005', 'Water Bottle 1L',               14,    17.99, 180, 1),
  (47, 'OD-1006', 'Rechargeable Headlamp',         14,    24.99,  95, 1),
  (48, 'FT-1101', 'Yoga Mat',                      15,    24.99, 130, 1),
  (49, 'FT-1102', 'Adjustable Dumbbell Set',       15,   199.00,  16, 1),
  (50, 'FT-1103', 'Resistance Bands Set',          15,    19.99, 160, 1),
  (51, 'FT-1104', 'Speed Jump Rope',               15,     9.99, 220, 1),
  (52, 'FT-1105', 'Foam Roller',                   15,    27.99,  70, 1),
  (53, 'FT-1106', 'Fitness Tracker Band',          15,    59.99,  85, 1),
  (54, 'FT-1107', 'Kettlebell 16kg',               15,    49.00,  30, 1),
  (55, 'FT-1108', 'Doorway Pull-up Bar',           15,    34.99,  45, 1),
  (56, 'FT-1109', 'Running Armband',               15,    12.99, 140, 1),
  (57, 'AC-5006', 'Retro Floppy Disk USB',          4,    24.99,   5, 0),
  (58, 'BK-6007', 'Legacy EJB Cookbook',            8,    19.99,   0, 0),
  (59, 'OF-9006', 'Fax Machine Deluxe',            12,   129.00,   0, 0),
  (60, 'FT-1110', 'Limited Edition Gym Towel',     15,    14.99, 300, 1);

-- Descriptions for 2 of every 3 products (the rest stay NULL on purpose).
UPDATE products p
JOIN categories c ON c.id = p.category_id
SET p.description = CONCAT(p.name, ' - a great choice from our ', c.name, ' range. Free returns within 30 days.')
WHERE MOD(p.id, 3) <> 0;

-- Product creation dates: oldest first.
UPDATE products
SET created_at = DATE_SUB(NOW(), INTERVAL (600 - id * 7) DAY),
    updated_at = DATE_SUB(NOW(), INTERVAL (600 - id * 7) DAY);

-- JSON attributes for electronics (other products keep NULL).
UPDATE products SET attributes = JSON_OBJECT('brand','Aero','ram_gb',16,'storage_gb',512,'screen_in',13.3,'warranty_months',24) WHERE id = 1;
UPDATE products SET attributes = JSON_OBJECT('brand','Nova','ram_gb',32,'storage_gb',1024,'screen_in',15.6,'warranty_months',24) WHERE id = 2;
UPDATE products SET attributes = JSON_OBJECT('brand','Orion','ram_gb',32,'storage_gb',2048,'screen_in',17.3,'gpu','dedicated','warranty_months',12) WHERE id = 3;
UPDATE products SET attributes = JSON_OBJECT('brand','Pixelon','storage_gb',256,'5g',TRUE,'colors',JSON_ARRAY('black','silver'),'warranty_months',12) WHERE id = 4;
UPDATE products SET attributes = JSON_OBJECT('brand','Galaxia','storage_gb',128,'5g',TRUE,'colors',JSON_ARRAY('blue','black','white'),'warranty_months',12) WHERE id = 5;
UPDATE products SET attributes = JSON_OBJECT('brand','Nordic','storage_gb',128,'5g',FALSE,'colors',JSON_ARRAY('black'),'warranty_months',12) WHERE id = 6;
UPDATE products SET attributes = JSON_OBJECT('brand','Soundly','wireless',TRUE,'noise_cancelling',TRUE,'warranty_months',24) WHERE id = 12;
UPDATE products SET attributes = JSON_OBJECT('brand','Soundly','wireless',TRUE,'noise_cancelling',FALSE,'warranty_months',12) WHERE id = 13;
UPDATE products SET attributes = JSON_OBJECT('brand','Studiox','wireless',FALSE,'noise_cancelling',FALSE,'warranty_months',12) WHERE id = 14;
UPDATE products SET attributes = JSON_OBJECT('brand','Linkr','ports',7,'warranty_months',12) WHERE id = 16;
UPDATE products SET attributes = JSON_OBJECT('brand','Liftup','material','aluminium','warranty_months',12) WHERE id = 17;
UPDATE products SET attributes = JSON_OBJECT('brand','Viewly','resolution','1080p','warranty_months',12) WHERE id = 18;
UPDATE products SET attributes = JSON_OBJECT('brand','Drivex','capacity_gb',1000,'warranty_months',36) WHERE id = 19;

-- Tags: every product gets up to two; about 1 in 11 products stays untagged.
INSERT INTO product_tags (product_id, tag_id)
SELECT id, 1 + MOD(id, 7) FROM products WHERE MOD(id, 11) <> 0
UNION
SELECT id, 1 + MOD(id * 3, 7) FROM products WHERE MOD(id, 11) <> 0;

-- =====================================================================
--  4. USERS
-- =====================================================================

-- 200 generated users. Every 10th user (10, 20, ...) never orders (see orders seed).
-- Every 25th user is soft-deleted. Every 6th has no phone, every 9th no birth date.
INSERT INTO users (email, first_name, last_name, phone, birth_date, status, created_at, deleted_at)
SELECT
  CONCAT('user', s.n, '@example.com'),
  ELT(1 + MOD(s.n, 20),
      'Oleksandr','Maria','Andrii','Olena','John','Emily','Michael','Sophie','Taras','Iryna',
      'David','Anna','Pavlo','Kateryna','Robert','Laura','Bohdan','Sofiia','Daniel','Natalia'),
  ELT(1 + MOD(s.n * 7 + s.n DIV 20, 20),
      'Shevchenko','Kovalenko','Bondarenko','Tkachenko','Smith','Johnson','Brown','Miller','Kowalski','Melnyk',
      'Williams','Taylor','Boyko','Kravchenko','Davis','Moore','Lysenko','Savchenko','Wilson','Clark'),
  CASE WHEN MOD(s.n, 6) = 0 THEN NULL
       ELSE CONCAT('+38050', LPAD(MOD(s.n * 7919, 10000000), 7, '0')) END,
  CASE WHEN MOD(s.n, 9) = 0 THEN NULL
       ELSE DATE_SUB(CURDATE(), INTERVAL (18 * 365 + MOD(s.n * 173, 14000)) DAY) END,
  CASE WHEN MOD(s.n, 17) = 0 THEN 'SUSPENDED'
       WHEN MOD(s.n, 13) = 0 THEN 'PENDING'
       ELSE 'ACTIVE' END,
  DATE_SUB(DATE_SUB(NOW(), INTERVAL (400 - MOD(s.n * 13, 380)) DAY), INTERVAL MOD(s.n * 7919, 86400) SECOND),
  CASE WHEN MOD(s.n, 25) = 0 THEN DATE_SUB(NOW(), INTERVAL 10 DAY) ELSE NULL END
FROM seq s
WHERE s.n BETWEEN 1 AND 200
ORDER BY s.n;

-- InnoDB may skip auto-increment values after a bulk INSERT ... SELECT; pin the counter
-- so the hand-made users below get predictable ids (201 to 210).
ALTER TABLE users AUTO_INCREMENT = 201;

-- Hand-made users with special properties.
INSERT INTO users (email, first_name, last_name, phone, birth_date, status, created_at) VALUES
  ('ivan.petrenko@example.com', 'Іван',  'Петренко', '+380671234567', '1990-05-14', 'ACTIVE',    DATE_SUB(NOW(), INTERVAL 300 DAY)),  -- Cyrillic (utf8mb4 test)
  ('olena.koval@example.com',   'Олена', 'Коваль',   NULL,           NULL,         'ACTIVE',    DATE_SUB(NOW(), INTERVAL 250 DAY)),
  ('john.smith@example.com',    'John',  'Smith',    '+14155550101', '1985-03-02', 'ACTIVE',    DATE_SUB(NOW(), INTERVAL 200 DAY)),  -- three "John Smith" = same name, different people
  ('john.smith2@example.com',   'John',  'Smith',    NULL,           '1992-11-23', 'ACTIVE',    DATE_SUB(NOW(), INTERVAL 180 DAY)),
  ('john.smith3@example.com',   'John',  'Smith',    '+442071838750','1978-07-09', 'SUSPENDED', DATE_SUB(NOW(), INTERVAL 150 DAY)),
  ('tester+plus@example.com',   'Test',  'Plus Sign',NULL,           NULL,         'PENDING',   DATE_SUB(NOW(), INTERVAL 5 DAY)),    -- '+' in email
  ('no.orders@example.com',     'Nora',  'Nobuy',    NULL,           NULL,         'ACTIVE',    DATE_SUB(NOW(), INTERVAL 30 DAY)),   -- no address, no orders
  ('admin@shop.example.com',    'Ada',   'Admin',    NULL,           NULL,         'ACTIVE',    DATE_SUB(NOW(), INTERVAL 500 DAY)),
  ('manager@shop.example.com',  'Max',   'Manager',  NULL,           NULL,         'ACTIVE',    DATE_SUB(NOW(), INTERVAL 450 DAY)),
  ('support@shop.example.com',  'Sam',   'Support',  NULL,           NULL,         'ACTIVE',    DATE_SUB(NOW(), INTERVAL 400 DAY));

UPDATE users SET updated_at = created_at;

-- Roles: everyone who is not staff is a CUSTOMER; staff get their own roles.
INSERT INTO user_roles (user_id, role_id, granted_at)
SELECT u.id, r.id, u.created_at
FROM users u
JOIN roles r ON r.name = 'CUSTOMER'
WHERE u.email NOT LIKE '%@shop.example.com';

INSERT INTO user_roles (user_id, role_id, granted_at)
SELECT u.id, r.id, u.created_at
FROM users u
JOIN roles r
  ON (u.email = 'admin@shop.example.com'   AND r.name IN ('ADMIN', 'MANAGER'))
  OR (u.email = 'manager@shop.example.com' AND r.name = 'MANAGER')
  OR (u.email = 'support@shop.example.com' AND r.name = 'SUPPORT');

-- Addresses: one default address per user (except no.orders@), a second one for every 3rd user.
INSERT INTO addresses (user_id, line1, city, postal_code, country_code, is_default)
SELECT u.id,
       CONCAT(10 + MOD(u.id * 3, 90), ' Main Street'),
       ELT(1 + MOD(u.id, 10), 'Kyiv','Lviv','Odesa','Warsaw','Krakow','Berlin','Munich','New York','London','Paris'),
       LPAD(MOD(u.id * 131, 100000), 5, '0'),
       ELT(1 + MOD(u.id, 10), 'UA','UA','UA','PL','PL','DE','DE','US','GB','FR'),
       1
FROM users u
WHERE u.email <> 'no.orders@example.com'
ORDER BY u.id;

INSERT INTO addresses (user_id, line1, city, postal_code, country_code, is_default)
SELECT u.id,
       CONCAT(1 + MOD(u.id * 5, 200), ' Second Avenue'),
       ELT(1 + MOD(u.id + 3, 10), 'Kyiv','Lviv','Odesa','Warsaw','Krakow','Berlin','Munich','New York','London','Paris'),
       LPAD(MOD(u.id * 977, 100000), 5, '0'),
       ELT(1 + MOD(u.id + 3, 10), 'UA','UA','UA','PL','PL','DE','DE','US','GB','FR'),
       0
FROM users u
WHERE MOD(u.id, 3) = 0 AND u.email <> 'no.orders@example.com'
ORDER BY u.id;

-- =====================================================================
--  5. ORDERS, ITEMS, PAYMENTS, HISTORY, REVIEWS
-- =====================================================================

-- 1200 orders. Users 1-20 are "heavy" buyers (every 4th order), users whose id is a
-- multiple of 10 never order. Status mix: 10% CANCELLED, 5% REFUNDED, 10% NEW (some
-- are old = abandoned carts), 15% PAID, 15% SHIPPED, 45% DELIVERED.
INSERT INTO orders (user_id, shipping_address_id, status, created_at)
SELECT u.id,
       a.id,
       ELT(1 + MOD(o.n, 20),
           'CANCELLED','CANCELLED','REFUNDED','NEW','NEW',
           'PAID','PAID','PAID','SHIPPED','SHIPPED','SHIPPED',
           'DELIVERED','DELIVERED','DELIVERED','DELIVERED','DELIVERED','DELIVERED','DELIVERED','DELIVERED','DELIVERED'),
       DATE_ADD(
         DATE_ADD(u.created_at,
                  INTERVAL MOD(o.n * 11, GREATEST(TIMESTAMPDIFF(DAY, u.created_at, NOW()), 1)) DAY),
         INTERVAL MOD(o.n * 7919, 86400) SECOND)
FROM (
  SELECT s.n,
         CASE WHEN MOD(s.n, 4) = 0 THEN 1 + MOD(s.n, 20) ELSE 1 + MOD(s.n * 37, 200) END AS raw_user
  FROM seq s
  WHERE s.n BETWEEN 1 AND 1200
) o
JOIN users u     ON u.id = CASE WHEN MOD(o.raw_user, 10) = 0 THEN o.raw_user - 1 ELSE o.raw_user END
JOIN addresses a ON a.user_id = u.id AND a.is_default = 1
ORDER BY o.n;

ALTER TABLE orders AUTO_INCREMENT = 1201;   -- tidy: new orders continue after id 1200

-- Items: slot 0 = a "hot" product (ids 1-6) for 60% of orders; slots 1..(1-4) = products 7..56.
-- Products 57-60 are never ordered. (order_id, product_id) is unique by construction.
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT o.id,
       p.id,
       1 + MOD(o.id + s.n, 3),
       p.price
FROM orders o
JOIN seq s ON s.n BETWEEN 0 AND 4
JOIN products p ON p.id = CASE WHEN s.n = 0 THEN 1 + MOD(o.id, 6)
                               ELSE 7 + MOD(o.id * 7 + s.n * 13, 50) END
WHERE (s.n = 0 AND MOD(o.id, 5) < 3)
   OR (s.n BETWEEN 1 AND 1 + MOD(o.id, 4))
ORDER BY o.id, s.n;

-- Denormalized total = sum of item lines.
UPDATE orders o
SET o.total_amount = (SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
                      FROM order_items oi
                      WHERE oi.order_id = o.id);

-- Shipping / delivery timestamps (capped at NOW()).
UPDATE orders
SET shipped_at = LEAST(NOW(), DATE_ADD(created_at, INTERVAL (1 + MOD(id, 3)) DAY))
WHERE status IN ('SHIPPED', 'DELIVERED');

UPDATE orders
SET delivered_at = LEAST(NOW(), DATE_ADD(shipped_at, INTERVAL (2 + MOD(id, 5)) DAY))
WHERE status = 'DELIVERED';

UPDATE orders SET updated_at = COALESCE(delivered_at, shipped_at, created_at);

-- Payments: one SUCCESS (or REFUNDED) payment for paid-ish orders ...
INSERT INTO payments (order_id, amount, method, status, created_at)
SELECT o.id,
       o.total_amount,
       ELT(1 + MOD(o.id, 4), 'CARD', 'CARD', 'PAYPAL', 'BANK_TRANSFER'),
       CASE WHEN o.status = 'REFUNDED' THEN 'REFUNDED' ELSE 'SUCCESS' END,
       LEAST(NOW(), DATE_ADD(o.created_at, INTERVAL 5 MINUTE))
FROM orders o
WHERE o.status IN ('PAID', 'SHIPPED', 'DELIVERED', 'REFUNDED');

-- ... an earlier FAILED attempt for every 7th paid-ish order, and for half of the cancelled ones ...
INSERT INTO payments (order_id, amount, method, status, created_at)
SELECT o.id, o.total_amount, 'CARD', 'FAILED', DATE_ADD(o.created_at, INTERVAL 1 MINUTE)
FROM orders o
WHERE (o.status IN ('PAID', 'SHIPPED', 'DELIVERED', 'REFUNDED') AND MOD(o.id, 7) = 0)
   OR (o.status = 'CANCELLED' AND MOD(o.id, 2) = 0);

-- ... and a PENDING payment for half of the NEW orders.
INSERT INTO payments (order_id, amount, method, status, created_at)
SELECT o.id, o.total_amount, 'PAYPAL', 'PENDING', DATE_ADD(o.created_at, INTERVAL 1 MINUTE)
FROM orders o
WHERE o.status = 'NEW' AND MOD(o.id, 2) = 0;

UPDATE payments
SET external_ref = CONCAT('TX-', LPAD(id, 8, '0'))
WHERE status IN ('SUCCESS', 'REFUNDED');

-- Status history for every order (what a real audit trail would contain).
INSERT INTO order_status_history (order_id, old_status, new_status, changed_at)
SELECT id, NULL, 'NEW', created_at FROM orders
UNION ALL
SELECT id, 'NEW', 'PAID', LEAST(NOW(), DATE_ADD(created_at, INTERVAL 5 MINUTE))
FROM orders WHERE status IN ('PAID', 'SHIPPED', 'DELIVERED', 'REFUNDED')
UNION ALL
SELECT id, 'PAID', 'SHIPPED', shipped_at FROM orders WHERE status IN ('SHIPPED', 'DELIVERED')
UNION ALL
SELECT id, 'SHIPPED', 'DELIVERED', delivered_at FROM orders WHERE status = 'DELIVERED'
UNION ALL
SELECT id, 'NEW', 'CANCELLED', LEAST(NOW(), DATE_ADD(created_at, INTERVAL 1 DAY)) FROM orders WHERE status = 'CANCELLED'
UNION ALL
SELECT id, 'PAID', 'REFUNDED', LEAST(NOW(), DATE_ADD(created_at, INTERVAL 10 DAY)) FROM orders WHERE status = 'REFUNDED';

-- Reviews: only from people whose order was delivered, about 1 in 4 purchases, one per user+product.
INSERT INTO reviews (user_id, product_id, rating, title, body, created_at)
SELECT r.user_id,
       r.product_id,
       r.rating,
       CASE WHEN MOD(r.user_id + r.product_id, 5) = 0 THEN NULL
            ELSE ELT(r.rating, 'Do not buy', 'Disappointing', 'It is okay', 'Good purchase', 'Excellent') END,
       CASE WHEN MOD(r.user_id + r.product_id, 3) = 0 THEN NULL
            ELSE ELT(r.rating, 'Broke after a week.', 'Below expectations.', 'Average, nothing special.',
                               'Works well, would buy again.', 'Perfect, exactly as described.') END,
       r.created_at
FROM (
  SELECT o.user_id,
         oi.product_id,
         CAST(ELT(1 + MOD(o.user_id * 3 + oi.product_id * 5, 10), 5, 5, 5, 4, 4, 4, 3, 3, 2, 1) AS UNSIGNED) AS rating,
         LEAST(NOW(), DATE_ADD(MIN(o.delivered_at), INTERVAL 7 DAY)) AS created_at
  FROM orders o
  JOIN order_items oi ON oi.order_id = o.id
  WHERE o.status = 'DELIVERED' AND MOD(o.id * 3 + oi.product_id, 4) = 0
  GROUP BY o.user_id, oi.product_id
) r;

-- =====================================================================
--  6. VIEWS
-- =====================================================================

CREATE VIEW v_order_summary AS
SELECT o.id            AS order_id,
       o.created_at,
       o.status,
       u.id            AS user_id,
       CONCAT(u.first_name, ' ', u.last_name) AS customer,
       u.email,
       o.total_amount,
       COALESCE(i.item_count, 0) AS item_count,
       COALESCE(i.units, 0)      AS units,
       COALESCE(p.paid, 0)       AS paid_amount
FROM orders o
JOIN users u ON u.id = o.user_id
LEFT JOIN (SELECT order_id, COUNT(*) AS item_count, SUM(quantity) AS units
           FROM order_items GROUP BY order_id) i ON i.order_id = o.id
LEFT JOIN (SELECT order_id, SUM(amount) AS paid
           FROM payments WHERE status = 'SUCCESS' GROUP BY order_id) p ON p.order_id = o.id;

CREATE VIEW v_product_stats AS
SELECT p.id AS product_id,
       p.sku,
       p.name,
       c.name AS category,
       p.price,
       p.stock_quantity,
       p.active,
       COALESCE(s.units_sold, 0)   AS units_sold,
       COALESCE(s.revenue, 0)      AS revenue,
       COALESCE(r.review_count, 0) AS review_count,
       r.avg_rating                                  -- NULL when there are no reviews
FROM products p
JOIN categories c ON c.id = p.category_id
LEFT JOIN (SELECT oi.product_id,
                  SUM(oi.quantity)                  AS units_sold,
                  SUM(oi.quantity * oi.unit_price)  AS revenue
           FROM order_items oi
           JOIN orders o ON o.id = oi.order_id
           WHERE o.status IN ('PAID', 'SHIPPED', 'DELIVERED')
           GROUP BY oi.product_id) s ON s.product_id = p.id
LEFT JOIN (SELECT product_id, COUNT(*) AS review_count, ROUND(AVG(rating), 2) AS avg_rating
           FROM reviews GROUP BY product_id) r ON r.product_id = p.id;

-- =====================================================================
--  7. FUNCTION, PROCEDURE, TRIGGERS
-- =====================================================================

DELIMITER $$

-- Sum of all "real" (paid, shipped, delivered) orders of a user.
CREATE FUNCTION fn_user_lifetime_value(p_user_id BIGINT)
RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(12,2);
  SELECT COALESCE(SUM(total_amount), 0) INTO v_total
  FROM orders
  WHERE user_id = p_user_id AND status IN ('PAID', 'SHIPPED', 'DELIVERED');
  RETURN v_total;
END$$

-- Places a single-product order inside one transaction:
-- validates input, locks the product row, checks stock, inserts order + item, decrements stock.
-- Any error rolls everything back and is re-raised to the caller (Java: SQLException).
CREATE PROCEDURE sp_place_order(
  IN  p_user_id    BIGINT,
  IN  p_address_id BIGINT,
  IN  p_product_id BIGINT,
  IN  p_quantity   INT,
  OUT p_order_id   BIGINT
)
BEGIN
  DECLARE v_price DECIMAL(10,2) DEFAULT NULL;
  DECLARE v_stock INT DEFAULT NULL;

  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;

  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be positive';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM users
                 WHERE id = p_user_id AND status = 'ACTIVE' AND deleted_at IS NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'User not found or not active';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM addresses WHERE id = p_address_id AND user_id = p_user_id) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Address does not belong to the user';
  END IF;

  START TRANSACTION;

  SELECT price, stock_quantity INTO v_price, v_stock
  FROM products
  WHERE id = p_product_id AND active = 1
  FOR UPDATE;

  IF v_price IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product not found or inactive';
  END IF;

  IF v_stock < p_quantity THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not enough stock';
  END IF;

  INSERT INTO orders (user_id, shipping_address_id, status, total_amount)
  VALUES (p_user_id, p_address_id, 'NEW', v_price * p_quantity);

  SET p_order_id = LAST_INSERT_ID();

  INSERT INTO order_items (order_id, product_id, quantity, unit_price)
  VALUES (p_order_id, p_product_id, p_quantity, v_price);

  UPDATE products SET stock_quantity = stock_quantity - p_quantity WHERE id = p_product_id;

  COMMIT;
END$$

-- Every price change is recorded.
CREATE TRIGGER trg_products_price_audit
AFTER UPDATE ON products
FOR EACH ROW
BEGIN
  IF NOT (OLD.price <=> NEW.price) THEN
    INSERT INTO price_audit (product_id, old_price, new_price)
    VALUES (NEW.id, OLD.price, NEW.price);
  END IF;
END$$

-- Every new order starts its history ...
CREATE TRIGGER trg_orders_history_insert
AFTER INSERT ON orders
FOR EACH ROW
BEGIN
  INSERT INTO order_status_history (order_id, old_status, new_status)
  VALUES (NEW.id, NULL, NEW.status);
END$$

-- ... and every status change is appended to it.
CREATE TRIGGER trg_orders_history_update
AFTER UPDATE ON orders
FOR EACH ROW
BEGIN
  IF NOT (OLD.status <=> NEW.status) THEN
    INSERT INTO order_status_history (order_id, old_status, new_status)
    VALUES (NEW.id, OLD.status, NEW.status);
  END IF;
END$$

DELIMITER ;

-- A few price changes AFTER the triggers exist, so price_audit has rows and
-- order_items.unit_price (snapshot) differs from products.price (current).
UPDATE products SET price = ROUND(price * 1.05, 2) WHERE id IN (1, 2, 3);
UPDATE products SET price = 449.00 WHERE id = 6;
UPDATE products SET price = ROUND(price * 0.90, 2) WHERE id IN (31, 42);

-- =====================================================================
--  8. CLEAN UP + SANITY CHECK
-- =====================================================================

DROP TABLE seq;
DROP TABLE digits;

SET SQL_SAFE_UPDATES = 1;

SELECT 'users' AS table_name, COUNT(*) AS row_count FROM users
UNION ALL SELECT 'user_roles',            COUNT(*) FROM user_roles
UNION ALL SELECT 'addresses',             COUNT(*) FROM addresses
UNION ALL SELECT 'categories',            COUNT(*) FROM categories
UNION ALL SELECT 'products',              COUNT(*) FROM products
UNION ALL SELECT 'tags',                  COUNT(*) FROM tags
UNION ALL SELECT 'product_tags',          COUNT(*) FROM product_tags
UNION ALL SELECT 'orders',                COUNT(*) FROM orders
UNION ALL SELECT 'order_items',           COUNT(*) FROM order_items
UNION ALL SELECT 'payments',              COUNT(*) FROM payments
UNION ALL SELECT 'reviews',               COUNT(*) FROM reviews
UNION ALL SELECT 'order_status_history',  COUNT(*) FROM order_status_history
UNION ALL SELECT 'price_audit',           COUNT(*) FROM price_audit;
