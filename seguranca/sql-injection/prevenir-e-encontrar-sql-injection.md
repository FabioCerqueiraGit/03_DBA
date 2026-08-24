# SQL Injection — prevenir na aplicação, encontrar no banco

> Como escrever código que não é injetável, e como auditar um sistema legado para descobrir onde
> ele já é.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 2.0+ e .NET Core/5+. T-SQL: SQL Server 2005+ (`sp_executesql` e `QUOTENAME` existem desde muito antes). |
| **Impacto** | O script de auditoria é somente leitura sobre catálogo. |
| **Permissões** | `VIEW DEFINITION` no banco auditado. |

---

## Problema

SQL Injection continua na lista de vulnerabilidades mais exploradas décadas depois de ter sido
documentada. O motivo não é falta de conhecimento sobre parâmetros — é que o problema quase sempre
está em três lugares que ninguém revisa:

1. **Stored procedures antigas** que montam SQL dinâmico com concatenação, escritas quando o filtro
   era opcional e ninguém queria escrever oito `IF`.
2. **Filtros e ordenações dinâmicas** — `ORDER BY @coluna` não aceita parâmetro, então alguém
   concatenou.
3. **Relatórios e telas de busca avançada**, onde a query é montada em tempo de execução a partir
   do que o usuário marcou.

O código novo, escrito com Entity Framework ou Dapper, costuma estar bem. O sistema de 2009 que
ainda fatura é onde mora o risco.

---

## A regra

> **Dado de entrada nunca vira parte do texto da query. Vira valor de parâmetro.**

A distinção não é estética. Um parâmetro trafega separado do texto do comando; o SQL Server nunca
o interpreta como código. Concatenação transforma dado em código — e esse é literalmente o
mecanismo da vulnerabilidade.

---

## Solução — ADO.NET

### Errado

```csharp
// NAO faca isso. O exemplo existe para ser reconhecido em codigo legado.
var sql = "SELECT Id, Nome FROM dbo.Cliente WHERE Documento = '" + documento + "'";
using var comando = new SqlCommand(sql, conexao);
```

Com `documento` valendo `' OR 1=1 --`, a query retorna a base inteira. Com
`'; DROP TABLE dbo.Cliente; --`, faz pior.

### Certo

```csharp
using Microsoft.Data.SqlClient;   // .NET Core/5+ e Framework moderno
// using System.Data.SqlClient;   // legado

const string sql = @"
    SELECT Id, Nome
      FROM dbo.Cliente
     WHERE Documento = @Documento;";

using var conexao = new SqlConnection(connectionString);
using var comando = new SqlCommand(sql, conexao);

// Declare tipo e tamanho explicitamente.
comando.Parameters.Add("@Documento", SqlDbType.VarChar, 14).Value = documento;

await conexao.OpenAsync(cancellationToken);
using var leitor = await comando.ExecuteReaderAsync(cancellationToken);
```

### Por que não `AddWithValue`

`AddWithValue` é seguro contra injeção — ele cria um parâmetro de verdade. O problema dele é
**performance**, e é sério o bastante para merecer o aviso aqui:

```csharp
comando.Parameters.AddWithValue("@Documento", documento);
// Uma string C# vira NVARCHAR(n). Se a coluna for VARCHAR, o SQL Server
// aplica CONVERT_IMPLICIT na COLUNA — e isso invalida o index seek.
```

O resultado é um scan em tabela grande, com o plano parecendo correto para quem não olha o
operador. Ver [`sql-server/performance/`](../../sql-server/performance/) para o diagnóstico de
SARGability.

Sempre declare tipo e tamanho:

```csharp
comando.Parameters.Add("@Documento", SqlDbType.VarChar, 14).Value = documento;
comando.Parameters.Add("@DataInicio", SqlDbType.DateTime2).Value = dataInicio;
comando.Parameters.Add("@Valor", SqlDbType.Decimal).Value = valor;
```

---

## Dapper

Dapper parametriza automaticamente objetos anônimos:

```csharp
var clientes = await conexao.QueryAsync<Cliente>(
    "SELECT Id, Nome FROM dbo.Cliente WHERE Documento = @Documento",
    new { Documento = documento });
```

O `IN` também é resolvido corretamente — Dapper expande a lista em parâmetros individuais
(`@Ids1, @Ids2, ...`), não em concatenação:

```csharp
var clientes = await conexao.QueryAsync<Cliente>(
    "SELECT Id, Nome FROM dbo.Cliente WHERE Id IN @Ids",
    new { Ids = listaDeIds });
```

Para forçar tipo e tamanho no Dapper, use `DbString`:

```csharp
new { Documento = new DbString { Value = documento, IsAnsi = true, Length = 14 } }
// IsAnsi = true gera VARCHAR em vez de NVARCHAR — evita o CONVERT_IMPLICIT.
```

**Onde o Dapper não protege:** qualquer parte da string que você montar por concatenação antes de
passar. Dapper parametriza os valores; ele não inspeciona o texto da query.

---

## Entity Framework

LINQ é parametrizado por construção:

```csharp
var clientes = await contexto.Clientes
    .Where(c => c.Documento == documento)
    .ToListAsync(cancellationToken);
```

O risco no EF está nas APIs de SQL cru. **A diferença de nome é sutil e importante:**

```csharp
// SEGURO — FromSql (EF Core 8+) e FromSqlInterpolated usam string interpolada,
// mas o EF converte cada {} em parametro. Nao e concatenacao.
var clientes = await contexto.Clientes
    .FromSql($"SELECT * FROM dbo.Cliente WHERE Documento = {documento}")
    .ToListAsync();

// PERIGOSO se voce montar a string antes
var sql = "SELECT * FROM dbo.Cliente WHERE Documento = '" + documento + "'";
var clientes = await contexto.Clientes
    .FromSqlRaw(sql)                     // <- injetavel
    .ToListAsync();

// FromSqlRaw usado corretamente, com parametros posicionais:
var clientes = await contexto.Clientes
    .FromSqlRaw("SELECT * FROM dbo.Cliente WHERE Documento = {0}", documento)
    .ToListAsync();
```

O mesmo vale para `ExecuteSqlRaw` versus `ExecuteSql`/`ExecuteSqlInterpolated`.

> **Regra prática de revisão de código:** todo `Raw` no nome do método é um ponto de atenção. Não
> é proibido — é obrigatório verificar de onde vem a string.

No **Entity Framework 6**, os equivalentes são `Database.SqlQuery<T>` e
`Database.ExecuteSqlCommand`, que aceitam `SqlParameter`:

```csharp
var clientes = contexto.Database.SqlQuery<Cliente>(
    "SELECT Id, Nome FROM dbo.Cliente WHERE Documento = @documento",
    new SqlParameter("@documento", SqlDbType.VarChar, 14) { Value = documento })
    .ToList();
```

---

## O caso difícil: `ORDER BY` e nome de coluna dinâmicos

Parâmetro não pode substituir identificador. `ORDER BY @coluna` não funciona — o SQL Server
ordenaria por uma constante.

**A solução não é escapar. É validar contra uma lista fixa.**

```csharp
// Lista branca. Se nao esta aqui, nao existe.
private static readonly Dictionary<string, string> ColunasOrdenacao =
    new(StringComparer.OrdinalIgnoreCase)
    {
        ["nome"]      = "c.Nome",
        ["documento"] = "c.Documento",
        ["cadastro"]  = "c.DataCadastro"
    };

public async Task<IReadOnlyList<Cliente>> BuscarAsync(
    string ordenarPor, bool descendente, CancellationToken cancellationToken)
{
    if (!ColunasOrdenacao.TryGetValue(ordenarPor ?? "nome", out var coluna))
        throw new ArgumentException("Coluna de ordenacao invalida.", nameof(ordenarPor));

    var direcao = descendente ? "DESC" : "ASC";

    // 'coluna' e 'direcao' vem de constantes do proprio codigo, nunca do usuario.
    var sql = $@"
        SELECT c.Id, c.Nome, c.Documento
          FROM dbo.Cliente AS c
         ORDER BY {coluna} {direcao}
         OFFSET @Pular ROWS FETCH NEXT @Quantidade ROWS ONLY;";

    // ...
}
```

O que torna isso seguro não é a interpolação cuidadosa — é o fato de que o valor interpolado só
pode ser um de três literais definidos no código-fonte. **Lista branca, nunca lista negra.**
Tentar "remover caracteres perigosos" é uma corrida que o atacante vence.

---

## SQL dinâmico dentro do SQL Server

Aqui mora a maior parte do risco em sistema legado.

### Errado

```sql
-- Vulneravel. Padrao muito comum em procedures de busca avancada.
CREATE PROCEDURE dbo.BuscarCliente
    @Nome NVARCHAR(100) = NULL
AS
BEGIN
    DECLARE @sql NVARCHAR(MAX);
    SET @sql = N'SELECT Id, Nome FROM dbo.Cliente WHERE 1 = 1';

    IF @Nome IS NOT NULL
        SET @sql = @sql + N' AND Nome LIKE ''%' + @Nome + N'%''';  -- INJETAVEL

    EXEC (@sql);
END
```

Dois erros: concatenação do valor e `EXEC (@sql)`, que não aceita parâmetros.

### Certo — `sp_executesql` com parâmetros

```sql
CREATE OR ALTER PROCEDURE dbo.BuscarCliente
    @Nome      NVARCHAR(100) = NULL,
    @Documento VARCHAR(14)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql NVARCHAR(MAX);

    SET @sql = N'
        SELECT c.Id, c.Nome, c.Documento
          FROM dbo.Cliente AS c
         WHERE 1 = 1';

    -- O TEXTO da query e montado condicionalmente.
    -- O VALOR nunca entra no texto: entra pelo parametro.
    IF @Nome IS NOT NULL
        SET @sql = @sql + N'
           AND c.Nome LIKE N''%'' + @pNome + N''%''';

    IF @Documento IS NOT NULL
        SET @sql = @sql + N'
           AND c.Documento = @pDocumento';

    SET @sql = @sql + N'
         ORDER BY c.Nome;';

    EXEC sys.sp_executesql
         @sql,
         N'@pNome NVARCHAR(100), @pDocumento VARCHAR(14)',
         @pNome      = @Nome,
         @pDocumento = @Documento;
END
```

Ganhos além da segurança: `sp_executesql` permite reuso de plano de execução, enquanto
`EXEC (@sql)` gera um texto diferente a cada valor e enche o plan cache.

### Quando o identificador é dinâmico — `QUOTENAME`

Se você realmente precisa montar nome de tabela, coluna ou schema em tempo de execução (rotina de
manutenção, por exemplo), use `QUOTENAME`:

```sql
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'SELECT COUNT_BIG(*) FROM '
         + QUOTENAME(@NomeSchema) + N'.' + QUOTENAME(@NomeTabela) + N';';

EXEC sys.sp_executesql @sql;
```

`QUOTENAME` envolve o valor em colchetes e **duplica colchetes internos**, o que impede a quebra
do delimitador.

Duas ressalvas honestas:

- `QUOTENAME` retorna `NULL` se a entrada tiver mais de 128 caracteres. Um `NULL` concatenado
  anula o `@sql` inteiro — a query vira `NULL` e nada executa. É falha segura, mas confusa de
  diagnosticar.
- `QUOTENAME` protege o delimitador, não a existência do objeto. Valide contra
  `sys.objects`/`sys.columns` quando o valor vier de fora:

```sql
IF NOT EXISTS (SELECT 1 FROM sys.tables AS t
                 JOIN sys.schemas AS s ON s.schema_id = t.schema_id
                WHERE s.name = @NomeSchema AND t.name = @NomeTabela)
BEGIN
    RAISERROR('Tabela inexistente.', 16, 1);
    RETURN;
END
```

### `EXECUTE AS` e escalonamento de privilégio

Uma procedure com `WITH EXECUTE AS OWNER` que contenha SQL dinâmico injetável entrega ao atacante
os privilégios do owner, não os do usuário chamador. Isso transforma uma injeção limitada em
comprometimento do banco. Procedures com `EXECUTE AS` merecem revisão prioritária.

---

## Auditoria — encontrar SQL dinâmico no banco existente

Este script não prova vulnerabilidade; ele produz a **lista de objetos que precisam ser lidos por
uma pessoa**. Em um banco legado, essa lista é o ponto de partida de qualquer trabalho sério.

```sql
/* ===========================================================================
   NOME       : encontrar-sql-dinamico-em-objetos.sql
   OBJETIVO   : Listar procedures, functions e triggers cujo codigo contem
                indicios de SQL dinamico montado por concatenacao, para
                revisao manual de risco de SQL Injection.

   COMPATIBILIDADE : SQL Server 2005+ (9.x). Azure SQL Database: sim.
   IMPACTO         : Nenhum. Somente leitura sobre catalogo do sistema.
   PERMISSOES      : VIEW DEFINITION no banco.
   TEMPO ESTIMADO  : < 5 segundos em bancos com milhares de objetos.

   ATENCAO    : O resultado e uma lista de CANDIDATOS, nao de vulnerabilidades
                confirmadas. Todo objeto listado precisa ser lido. Uso de
                sp_executesql com parametros e correto e vai aparecer aqui.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */

SET NOCOUNT ON;

SELECT
    s.name                                              AS schema_objeto,
    o.name                                              AS nome_objeto,
    o.type_desc                                         AS tipo,
    -- Sinais de risco, do mais grave para o menos grave
    CASE WHEN m.definition LIKE '%EXEC%(%@%'
          AND m.definition NOT LIKE '%sp_executesql%'
         THEN 'ALTO - EXEC(@variavel) sem sp_executesql'
         WHEN m.definition LIKE '%sp_executesql%'
          AND m.definition LIKE '%+ @%'
         THEN 'MEDIO - sp_executesql com concatenacao de variavel'
         WHEN m.definition LIKE '%sp_executesql%'
         THEN 'BAIXO - sp_executesql (verificar se parametriza)'
         ELSE 'REVISAR'
    END                                                 AS classificacao,
    CASE WHEN m.execute_as_principal_id IS NOT NULL
         THEN 'SIM - privilegio elevado'
         ELSE 'nao'
    END                                                 AS usa_execute_as,
    o.modify_date                                       AS ultima_alteracao,
    LEN(m.definition)                                   AS tamanho_definicao
FROM sys.sql_modules  AS m
JOIN sys.objects      AS o ON o.object_id = m.object_id
JOIN sys.schemas      AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND (
        m.definition LIKE '%EXEC%(%@%'
     OR m.definition LIKE '%EXECUTE%(%@%'
     OR m.definition LIKE '%sp_executesql%'
      )
ORDER BY
    CASE WHEN m.execute_as_principal_id IS NOT NULL THEN 0 ELSE 1 END,
    CASE WHEN m.definition LIKE '%EXEC%(%@%'
          AND m.definition NOT LIKE '%sp_executesql%' THEN 0 ELSE 1 END,
    s.name, o.name;

/* ---------------------------------------------------------------------------
   COMO LER O RESULTADO

   classificacao = 'ALTO'
       EXEC (@variavel) nao aceita parametros. Se a variavel foi montada com
       qualquer valor vindo de parametro da procedure, ha risco real.
       Prioridade maxima de revisao.

   classificacao = 'MEDIO'
       Usa sp_executesql, mas ha concatenacao (+ @) no codigo. Pode ser
       montagem legitima do TEXTO (adicionar um AND condicional) ou pode ser
       concatenacao do VALOR. So a leitura do codigo diz.

   usa_execute_as = 'SIM'
       A procedure roda com privilegio de outro principal. Uma injecao aqui
       escala privilegio. Revise estas primeiro, independentemente da
       classificacao.

   Para ler a definicao completa de um objeto:
       EXEC sp_helptext 'dbo.NomeDaProcedure';
   ou:
       SELECT definition FROM sys.sql_modules
        WHERE object_id = OBJECT_ID('dbo.NomeDaProcedure');
   --------------------------------------------------------------------------- */
```

---

## Defesa em profundidade — o que a aplicação sozinha não resolve

Parametrizar impede a injeção. **Menor privilégio limita o estrago quando alguma coisa passa.**

O login da aplicação não deveria ser `db_owner`. O padrão mínimo razoável:

```sql
-- ATENCAO: script de EXEMPLO. Adapte nomes e revise antes de executar.
-- Cria um usuario com permissao restrita ao necessario.

CREATE ROLE app_execucao;

-- Permissao de execucao no schema onde ficam as procedures da aplicacao
GRANT EXECUTE ON SCHEMA::dbo TO app_execucao;

-- Se a aplicacao usa ORM e precisa de DML direto, conceda por schema,
-- nao por db_datareader/db_datawriter no banco inteiro:
GRANT SELECT, INSERT, UPDATE, DELETE ON SCHEMA::dbo TO app_execucao;

-- O que NAO conceder ao usuario da aplicacao:
--   ALTER, CONTROL, db_owner, db_ddladmin, sysadmin
--   VIEW SERVER STATE (a menos que a aplicacao realmente monitore)
--   Permissao sobre xp_cmdshell (que deve estar desabilitado)

ALTER ROLE app_execucao ADD MEMBER [<usuario-da-aplicacao>];
```

Isso muda o desfecho de uma injeção bem-sucedida: de "atacante executou `xp_cmdshell` no servidor"
para "atacante leu dados que a aplicação já lia". Ainda é grave; não é o fim.

Ver [`sql-server/administracao/`](../../sql-server/administracao/) para o detalhamento de
permissões e menor privilégio.

Complementos úteis:

- **Sempre TLS** entre aplicação e banco — `Encrypt=True` é o padrão no
  `Microsoft.Data.SqlClient` 4.0+.
- **Mensagem de erro genérica ao usuário final.** Devolver a exceção do SQL Server para a tela
  entrega nome de tabela, coluna e estrutura ao atacante. Registre o detalhe no log; devolva um
  identificador de correlação. Ver [`dotnet/logging/`](../../dotnet/logging/).
- **Validação de entrada** continua valendo — mas como qualidade de dado, não como defesa contra
  injeção. Um CPF deve ter 11 dígitos porque é um CPF, não porque isso "evita injeção".

---

## Quando NÃO utilizar SQL dinâmico

Antes de escrever SQL dinâmico, pergunte se ele é necessário:

| Motivo alegado | Alternativa |
|---|---|
| "Os filtros são opcionais" | `WHERE (@Nome IS NULL OR c.Nome = @Nome)` com `OPTION (RECOMPILE)` resolve na maioria dos casos, com plano adequado a cada combinação |
| "A ordenação é escolhida pelo usuário" | Lista branca no código da aplicação (ver acima) |
| "A tabela varia" | Reveja o modelo. Tabela cujo nome é dado costuma ser sinal de modelagem que deveria ser uma coluna |
| "É mais rápido" | Meça. `sp_executesql` com parâmetros reusa plano; concatenação não |

`OPTION (RECOMPILE)` tem custo de CPU por execução e não deve ir em query executada milhares de
vezes por minuto — mas para tela de busca avançada, executada dezenas de vezes por hora, é
frequentemente a escolha certa.

---

## Checklist de revisão

- [ ] Nenhuma concatenação de valor de entrada em texto de query, na aplicação ou no banco.
- [ ] Parâmetros declarados com **tipo e tamanho** explícitos (não só `AddWithValue`).
- [ ] Todo `FromSqlRaw` / `ExecuteSqlRaw` / `SqlQuery` auditado quanto à origem da string.
- [ ] Colunas de ordenação e filtros dinâmicos validados por **lista branca**.
- [ ] SQL dinâmico no banco usa `sp_executesql` com parâmetros, nunca `EXEC (@sql)`.
- [ ] Identificadores dinâmicos passam por `QUOTENAME` **e** validação de existência.
- [ ] Procedures com `EXECUTE AS` revisadas individualmente.
- [ ] Usuário da aplicação não é `db_owner` nem `sysadmin`.
- [ ] `xp_cmdshell` desabilitado.
- [ ] Exceção de banco não chega ao usuário final.
- [ ] Script de auditoria executado e a lista de candidatos efetivamente lida.

---

## Referências

- [Microsoft Learn — `sp_executesql`](https://learn.microsoft.com/sql/relational-databases/system-stored-procedures/sp-executesql-transact-sql)
- [Microsoft Learn — `QUOTENAME`](https://learn.microsoft.com/sql/t-sql/functions/quotename-transact-sql)
- [Microsoft Learn — EF Core: SQL queries (`FromSql`, `FromSqlRaw`)](https://learn.microsoft.com/ef/core/querying/sql-queries)
- [Microsoft Learn — `SqlParameter`](https://learn.microsoft.com/dotnet/api/microsoft.data.sqlclient.sqlparameter)
- [OWASP — SQL Injection Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)

---

**Criado por Fábio Cerqueira**
