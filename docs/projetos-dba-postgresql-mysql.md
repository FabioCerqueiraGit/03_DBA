# Projetos de DBA — PostgreSQL e MySQL

> **Nota de preservação.** Este documento é o conteúdo original do `README.md` deste
> repositório, mantido na íntegra quando a raiz passou a hospedar também a biblioteca de
> C#/.NET e SQL Server. Nada foi removido. O projeto `postgresql-audit-logger/` continua
> no lugar de origem.

---

# 🧾 Repositório Projetos de DBA

Este documento descreve o funcionamento técnico de 4 soluções usadas no dia a dia de um DBA que trabalhe com PostgreSQL e Mysql

## 🚀 1. Auditoria Avançada em PostgreSQL

### 🔍 Objetivo:
Implementar uma solução de auditoria completa usando triggers, tabelas de log, controle de permissões e criptografia de dados sensíveis.

### 🧰 Tecnologias:
- PostgreSQL 14+
- PL/pgSQL
- pgcrypto
- Docker (para facilitar execução)

### ✨ Destaques:
- Auditoria de INSERT, UPDATE e DELETE em tabelas críticas.
- Logs com old e new values.
- Criptografia com pgcrypto para dados sensíveis (CPF, email).
- Controle de acesso com Row-Level Security (RLS).
- Documentação explicando cada parte.

## 🧠 2. Otimização de Performance em MySQL com EXPLAIN e Índices

### 🔍 Objetivo:
Criar um banco com consultas reais (ex: ecommerce), identificar gargalos com EXPLAIN, e mostrar o impacto de índices e tuning.

### 🧰 Tecnologias:
- MySQL 8
- Workbench ou CLI
- Scripts SQL
- Docker + dados de carga (mock data)

### ✨ Destaques:
- Relatório com antes/depois da otimização.
- Casos reais: JOIN, GROUP BY, ORDER BY, LIKE, etc.
- Uso de índices compostos, cobertura, índice parcial.
- Análise de estatísticas com SHOW PROFILE ou performance_schema.

## 📊 3. Dashboard de Monitoramento com PostgreSQL + Grafana

### 🔍 Objetivo:
Montar um painel interativo para monitorar saúde e performance de um banco PostgreSQL.

### 🧰 Tecnologias:
- PostgreSQL
- Grafana + Prometheus
- pg_stat_statements
- Docker Compose

### ✨ Destaques:
- Visualização de conexões, queries lentas, locks, uso de disco/memória.
- Alertas de uso alto.
- Coleta automática com Prometheus.
- Repositório com setup completo em Docker e exemplos reais.

## 🛡️ 4. Backup e Recuperação Profissional em MySQL e PostgreSQL

### 🔍 Objetivo:
Criar um projeto que mostre boas práticas de backup full/incremental, restore, e disaster recovery em bancos MySQL e PostgreSQL.

### 🧰 Tecnologias:
- pg_dump, pg_restore, pg_basebackup
- mysqldump, mysqlpump, mysqlbinlog
- Bash scripts automatizados
- Docker + cron + logs

### ✨ Destaques:
- Scripts de backup automático com versionamento.
- Simulação de falhas e recuperação passo a passo.
- Backup criptografado e com hash de verificação.
- README com instruções claras e logs dos testes.

## 👨‍💻 Desenvolvido por

**Fabio Cerqueira** – DBA focado em performance, segurança e automação de banco de dados PostgreSQL e MySQL.

---

**Criado por Fábio Cerqueira**
