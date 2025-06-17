
# 🧾 Explicação Técnica: PostgreSQL Audit Logger

Este documento descreve o funcionamento técnico da solução de auditoria de dados sensíveis utilizando PostgreSQL, como foi implementada no projeto `PostgreSQL Audit Logger`.

---

## 🎯 Objetivo

Capturar e registrar automaticamente alterações realizadas em uma tabela de dados sensíveis (`usuarios`), garantindo:
- Rastreabilidade completa (quem alterou o quê e quando)
- Segurança de dados com criptografia
- Controle de acesso com políticas de Row-Level Security (RLS)

---

## 🛠 Componentes Técnicos

### 1. **Schema de Auditoria**
Utilizamos o schema `audit` para isolar a tabela de log, melhorando organização e segurança:

```sql
CREATE SCHEMA audit;
```

---

### 2. **Tabela Principal: `usuarios`**

Contém os dados sensíveis a serem auditados:
- `nome`
- `email`
- `cpf` (criptografado com `pgcrypto`)

---

### 3. **Tabela de Auditoria: `audit.log_usuarios`**

Armazena cada operação realizada na tabela `usuarios`, com:
- `operacao`: tipo (INSERT, UPDATE, DELETE)
- `dados_anteriores`: versão antiga (em UPDATE/DELETE)
- `dados_novos`: nova versão (em INSERT/UPDATE)
- `data_operacao`: timestamp

---

### 4. **Trigger Function de Auditoria**

A função `audit.log_modificacoes_usuarios()` é chamada automaticamente em cada operação e insere as informações no log como JSONB:

```plpgsql
IF TG_OP = 'INSERT' THEN ...
ELSIF TG_OP = 'UPDATE' THEN ...
ELSIF TG_OP = 'DELETE' THEN ...
```

---

### 5. **Criptografia com `pgcrypto`**

A coluna `cpf` é convertida para `BYTEA` e criptografada com:

```sql
pgp_sym_encrypt(p_cpf, 'chave-secreta')
```

A função `inserir_usuario_seguro()` assegura que os dados sempre sejam inseridos de forma segura.

---

### 6. **Row-Level Security (RLS)**

RLS é ativado para controlar o acesso ao log:

```sql
ALTER TABLE audit.log_usuarios ENABLE ROW LEVEL SECURITY;
```

Uma política básica permite somente leitura pública (pode ser ajustada conforme a necessidade real).

---

## ✅ Benefícios

- 🔐 Segurança: dados sensíveis são criptografados.
- 📜 Auditoria: cada alteração fica registrada de forma imutável.
- ⚙️ Escalável: arquitetura modular para aplicar em qualquer tabela.
- 👮‍♂️ Conformidade: atende a requisitos de rastreabilidade da LGPD e auditorias de segurança.

---

## 💡 Possíveis Extensões

- Log de IP e usuário logado (`inet_client_addr()`, `current_user`)
- Exportação automática dos logs em JSON/CSV
- Dashboard com Grafana ou Metabase para análise de alterações
- Notificações em tempo real com `LISTEN/NOTIFY`

---

## 🧪 Teste Rápido

```sql
SELECT inserir_usuario_seguro('João', 'joao@email.com', '123.456.789-00');

UPDATE usuarios SET nome = 'João Atualizado' WHERE id = 1;
DELETE FROM usuarios WHERE id = 1;

SELECT * FROM audit.log_usuarios;
```

---

## 👨‍💻 Desenvolvido por

**Fabio Cerqueira** – DBA focado em performance, segurança e automação de banco de dados PostgreSQL e MySQL.
