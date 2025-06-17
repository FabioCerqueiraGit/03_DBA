# 🛡️ PostgreSQL Audit Logger

Sistema de auditoria avançado para PostgreSQL com triggers, criptografia e Row-Level Security (RLS). Ideal para DBAs que precisam registrar alterações em tabelas sensíveis de forma robusta e rastreável.

---

## 📌 Funcionalidades

- 🔄 Log automático de **INSERT**, **UPDATE** e **DELETE** usando triggers.
- 🔐 **Criptografia de dados sensíveis** (como CPF) usando `pgcrypto`.
- 🔍 Armazenamento de **dados anteriores e novos** em JSONB.
- 🧑‍💻 Função segura de inserção com criptografia.
- 🔒 **Row-Level Security** para controlar quem pode visualizar os logs.

---

## 🧱 Estrutura do Projeto

- `sql/`: Scripts SQL divididos por etapa.
- `docs/`: Documentação e imagens explicativas.
- `docker/`: Configuração para rodar o projeto via Docker (PostgreSQL).
- `README.md`: Este documento.
- `LICENSE`: Licença BSD-like do PostgreSQL.

---

## 🚀 Como Executar

### Usando Docker
```bash
cd docker
docker-compose up -d
