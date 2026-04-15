-- Database migration to v12
-- Adicionando campos calcTithe y subFundPercent a categories
ALTER TABLE categories ADD COLUMN calcTithe BOOLEAN NOT NULL DEFAULT 1;
ALTER TABLE categories ADD COLUMN subFundPercent REAL NOT NULL DEFAULT 0;

-- Adicionando campo calcTithe a transactions
ALTER TABLE transactions ADD COLUMN calcTithe BOOLEAN NOT NULL DEFAULT 1;
