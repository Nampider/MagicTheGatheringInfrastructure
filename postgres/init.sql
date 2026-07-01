SELECT 'CREATE DATABASE marketplace_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'marketplace_db')\gexec

SELECT 'CREATE DATABASE account_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'account_db')\gexec

SELECT 'CREATE DATABASE keycloak_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'keycloak_db')\gexec

SELECT 'CREATE DATABASE commerce_db'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'commerce_db')\gexec
