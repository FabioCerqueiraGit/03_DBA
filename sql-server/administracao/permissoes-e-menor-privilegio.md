# Permissões e menor privilégio no SQL Server

> A aplicação conecta como `sa`. Todo mundo sabe que está errado, ninguém sabe por onde
> começar a corrigir. Este documento mostra o caminho, sem parar o sistema no processo.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: parcial |
| **Impacto** | **Alto.** Remover permissão em uso derruba funcionalidade |
| **Permissões** | `securityadmin` ou `sysadmin` |

---

## Login, usuário, papel: o modelo em uma tabela

| Conceito | Escopo | Onde vive | Serve para |
|---|---|---|---|
| **Login** | Instância | `sys.server_principals` | Autenticar — entrar no servidor |
| **Usuário** | Banco | `sys.database_principals` | Autorizar — fazer algo dentro de um banco |
| **Server role** | Instância | `sysadmin`, `securityadmin`, ... | Agrupar permissões de instância |
| **Database role** | Banco | `db_owner`, `db_datareader`, ... | Agrupar permissões de banco |
| **Schema** | Banco | `dbo`, `Vendas`, ... | Agrupar objetos e conceder em bloco |

Um login sem usuário mapeado entra na instância e não consegue usar banco nenhum. Um
usuário sem login é um usuário **órfão** — o clássico "restaurei o banco em outro servidor
e a aplicação não conecta".

---

## Diagnóstico: quem tem o quê

```sql
/* Logins com privilegio de instancia elevado.
   A lista de sysadmin deve ser curta e voce deve reconhecer cada nome. */
SELECT
    login       = sp.name,
    tipo        = sp.type_desc,
    papel       = r.name,
    habilitado  = CASE WHEN sp.is_disabled = 1 THEN 'nao' ELSE 'sim' END,
    criado_em   = sp.create_date
FROM sys.server_role_members AS srm
INNER JOIN sys.server_principals AS r  ON r.principal_id  = srm.role_principal_id
INNER JOIN sys.server_principals AS sp ON sp.principal_id = srm.member_principal_id
WHERE r.name IN ('sysadmin', 'securityadmin', 'serveradmin',
                 'setupadmin', 'processadmin', 'diskadmin', 'dbcreator')
ORDER BY r.name, sp.name;
```

```sql
/* Permissoes efetivas dentro do banco corrente.
   Rode apos USE [<BANCO>]. */
SELECT
    usuario     = dp.name,
    tipo        = dp.type_desc,
    permissao   = p.permission_name,
    estado      = p.state_desc,
    objeto      = CASE
                      WHEN p.class_desc = 'DATABASE' THEN '(banco inteiro)'
                      WHEN p.class_desc = 'SCHEMA'   THEN 'schema: ' + SCHEMA_NAME(p.major_id)
                      ELSE ISNULL(OBJECT_SCHEMA_NAME(p.major_id) + '.'
                                  + OBJECT_NAME(p.major_id), '(outro)')
                  END,
    classe      = p.class_desc
FROM sys.database_permissions AS p
INNER JOIN sys.database_principals AS dp
        ON dp.principal_id = p.grantee_principal_id
WHERE dp.name NOT IN ('public', 'dbo', 'guest',
                      'INFORMATION_SCHEMA', 'sys')
ORDER BY dp.name, p.class_desc, p.permission_name;
```

```sql
/* Membros de papeis do banco corrente */
SELECT
    papel   = r.name,
    membro  = m.name,
    tipo    = m.type_desc
FROM sys.database_role_members AS drm
INNER JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
INNER JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
ORDER BY r.name, m.name;
```

```sql
/* Usuarios orfaos: existem no banco e nao tem login correspondente */
SELECT
    usuario = dp.name,
    dp.type_desc,
    dp.create_date
FROM sys.database_principals AS dp
LEFT JOIN sys.server_principals AS sp
       ON sp.sid = dp.sid
WHERE dp.type IN ('S', 'U', 'G')
  AND dp.authentication_type_desc <> 'NONE'
  AND sp.sid IS NULL
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys');

/* Correcao do mapeamento */
-- ALTER USER [<USUARIO>] WITH LOGIN = [<LOGIN>];
```

---

## O caminho para sair do `sa`

Trocar a connection string de uma vez costuma derrubar alguma coisa. O caminho seguro tem
quatro passos.

### Passo 1 — Descobrir o que a aplicação realmente faz

Não pergunte ao desenvolvedor; observe. Uma sessão de Extended Events filtrada pelo
`Application Name` da aplicação, rodando por um ciclo de negócio completo, mostra quais
objetos são acessados e quais comandos são emitidos.

Esse é mais um motivo para configurar `Application Name` na connection string.

### Passo 2 — Criar um papel com o mínimo necessário

```sql
/* Papel especifico da aplicacao, no banco */
CREATE ROLE [app_pedidos_rw];

/* Conceder por SCHEMA, nao objeto a objeto: objetos novos ja nascem cobertos */
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::[Vendas] TO [app_pedidos_rw];
GRANT EXECUTE                        ON SCHEMA::[Vendas] TO [app_pedidos_rw];

/* Se a aplicacao le algo de outro schema, conceda apenas leitura */
GRANT SELECT ON SCHEMA::[Cadastro] TO [app_pedidos_rw];
```

### Passo 3 — Criar o login e o usuário

```sql
/* Login de instancia. Use senha forte, gerada, e guardada em cofre de segredos. */
CREATE LOGIN [app_pedidos]
WITH PASSWORD = N'<SENHA-FORTE-GERADA>',
     CHECK_POLICY = ON,
     DEFAULT_DATABASE = [<BANCO>];

USE [<BANCO>];
CREATE USER [app_pedidos] FOR LOGIN [app_pedidos];
ALTER ROLE [app_pedidos_rw] ADD MEMBER [app_pedidos];
```

Quando possível, prefira **autenticação do Windows** com conta de serviço gerenciada, ou
identidade gerenciada no Azure: elimina a senha da connection string.

### Passo 4 — Trocar, observar, remover

1. troque a connection string em **um** ambiente;
2. observe por um ciclo completo, monitorando erros de permissão;
3. conceda o que faltar — sempre o mínimo, nunca `db_owner` "para destravar";
4. só depois de estável, propague para produção;
5. por fim, remova o acesso antigo.

---

## Erros comuns e o que fazer no lugar

| Antipadrão | Problema | Alternativa |
|---|---|---|
| Aplicação conecta como `sa` | Qualquer SQL Injection vira controle total da instância | Login próprio com papel específico |
| Aplicação em `db_owner` | Pode apagar tabelas, alterar esquema e conceder permissões | Papel com `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`EXECUTE` por schema |
| `db_datareader` + `db_datawriter` em tudo | Lê e escreve em qualquer tabela, inclusive as que não deveria | Permissão por schema |
| `GRANT` direto ao usuário | Vira impossível de auditar e de replicar em outro ambiente | Sempre via papel |
| Senha de aplicação na connection string em texto claro | Vaza em log, em repositório, em dump | Cofre de segredos, ou autenticação integrada |
| `sa` habilitado com senha fraca | Alvo número um de ataque automatizado | Renomear ou desabilitar o `sa`, com outro `sysadmin` funcionando antes |
| `xp_cmdshell` habilitado | Executa comando do sistema operacional a partir do banco | Manter desabilitado; se preciso, isolar e auditar |

### Verificações rápidas de superfície de ataque

```sql
SELECT name, value_in_use, description
FROM sys.configurations
WHERE name IN ('xp_cmdshell',
               'Ole Automation Procedures',
               'remote admin connections',
               'clr enabled',
               'Database Mail XPs');

/* Status do sa */
SELECT name, is_disabled, create_date, modify_date
FROM sys.server_principals
WHERE sid = 0x01;
```

---

## Permissões que o time de DBA precisa — sem ser `sysadmin`

Muita gente vira `sysadmin` só para poder diagnosticar. Não precisa:

```sql
/* Ler DMVs de diagnostico -- suficiente para quase todos os scripts
   de troubleshooting deste repositorio */
GRANT VIEW SERVER STATE TO [<LOGIN>];

/* Ver definicao de objetos (indices, procedures) */
GRANT VIEW ANY DEFINITION TO [<LOGIN>];

/* Encerrar sessoes -- conceda com criterio */
GRANT ALTER ANY CONNECTION TO [<LOGIN>];
```

Com esses três, uma pessoa de plantão consegue diagnosticar praticamente tudo sem poder
alterar dado nenhum. É o equilíbrio certo entre autonomia e risco.

---

## Checklist

- [ ] A lista de `sysadmin` é curta e você reconhece cada nome.
- [ ] Nenhuma aplicação conecta como `sa`.
- [ ] Nenhuma aplicação está em `db_owner`.
- [ ] Permissões concedidas via **papel**, nunca direto ao usuário.
- [ ] Senhas fora do código e fora do repositório.
- [ ] `xp_cmdshell` desabilitado (ou justificado por escrito).
- [ ] Sem usuários órfãos depois de restores.
- [ ] Logins de pessoas que saíram da empresa foram removidos.
- [ ] Revisão periódica de quem tem o quê.

## Referências

- [Permissões (Mecanismo de Banco de Dados)](https://learn.microsoft.com/pt-br/sql/relational-databases/security/permissions-database-engine)
- [Hierarquia de permissões](https://learn.microsoft.com/pt-br/sql/relational-databases/security/permissions-hierarchy-database-engine)
- [Funções no nível do servidor](https://learn.microsoft.com/pt-br/sql/relational-databases/security/authentication-access/server-level-roles)
- [Funções no nível do banco de dados](https://learn.microsoft.com/pt-br/sql/relational-databases/security/authentication-access/database-level-roles)

---

**Criado por Fábio Cerqueira**
