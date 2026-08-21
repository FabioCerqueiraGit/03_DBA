# Dapper — receitas essenciais

> Dapper é um micro-ORM: mapeia o resultado para objetos e sai do caminho. Você escreve o
> SQL. Isso o torna previsível — e transfere para você a responsabilidade que um ORM
> completo assumiria.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Pacotes** | `Dapper` · `Microsoft.Data.SqlClient` |
| **Impacto** | O SQL é seu: performance e segurança dependem dele |

---

## Quando usar Dapper, e quando não

| Use Dapper quando | Prefira EF Core quando |
|---|---|
| A consulta é complexa e você quer controlar o SQL | O modelo é rico e há muita navegação entre entidades |
| É leitura de alto volume, sensível a latência | Há escrita com rastreamento de mudanças |
| Já existem stored procedures que você vai reutilizar | Você quer migrations gerenciadas |
| Você está em legado e não quer introduzir um ORM completo | A produtividade de CRUD importa mais que o SQL fino |

Os dois convivem bem no mesmo projeto: EF Core para escrita e agregados, Dapper para
relatórios e consultas críticas.

---

## Consulta básica

```csharp
using Dapper;
using Microsoft.Data.SqlClient;

await using var conexao = new SqlConnection(_connectionString);

const string sql = @"
    SELECT  p.PedidoId,
            p.Data,
            p.Valor,
            p.ClienteId
    FROM    dbo.Pedido AS p
    WHERE   p.ClienteId = @ClienteId
      AND   p.Data >= @DataInicial
    ORDER BY p.Data DESC;";

var pedidos = await conexao.QueryAsync<Pedido>(
    new CommandDefinition(
        sql,
        new { ClienteId = clienteId, DataInicial = dataInicial },
        commandTimeout: 30,
        cancellationToken: cancellationToken));
```

`CommandDefinition` é o que permite passar `CancellationToken` — as sobrecargas simples de
`QueryAsync` não o aceitam. Use-o sempre em código de produção.

O objeto anônimo vira parametrização real (`@ClienteId`, `@DataInicial`), não concatenação.

---

## Tipos de retorno

```csharp
// Varias linhas
var lista = await conexao.QueryAsync<Pedido>(cmd);

// Uma linha ou nenhuma; lanca se vier mais de uma
var pedido = await conexao.QuerySingleOrDefaultAsync<Pedido>(cmd);

// Exatamente uma; lanca se vier zero ou mais de uma
var obrigatorio = await conexao.QuerySingleAsync<Pedido>(cmd);

// A primeira, ignorando as demais
var primeira = await conexao.QueryFirstOrDefaultAsync<Pedido>(cmd);

// Valor escalar
var total = await conexao.ExecuteScalarAsync<int>(cmd);

// Comando sem retorno; devolve linhas afetadas
var afetadas = await conexao.ExecuteAsync(cmd);
```

Prefira `QuerySingleOrDefault` a `QueryFirstOrDefault` quando o resultado **deveria** ser
único: se vier duplicado, você quer saber, não quer que o segundo seja silenciosamente
ignorado.

---

## Tipagem explícita de parâmetros

O objeto anônimo é conveniente, mas infere o tipo — e a inferência para `string` é
`NVARCHAR`. Contra uma coluna `VARCHAR`, isso gera **conversão implícita** e o índice
deixa de servir para busca.

```csharp
// ⚠️ Documento e VARCHAR(20) no banco; o parametro vai como NVARCHAR
var cliente = await conexao.QuerySingleOrDefaultAsync<Cliente>(
    sql, new { Documento = documento });

// ✅ Tipo e tamanho explicitos
var parametros = new DynamicParameters();
parametros.Add("@Documento", documento, DbType.AnsiString, size: 20);

var cliente = await conexao.QuerySingleOrDefaultAsync<Cliente>(
    new CommandDefinition(sql, parametros, cancellationToken: cancellationToken));
```

`DbType.AnsiString` corresponde a `VARCHAR`; `DbType.String` corresponde a `NVARCHAR`.
Essa é uma das causas de "a query é rápida no SSMS e lenta na aplicação". Detalhes em
[`../../sql-server/performance/sargability-e-indices-ignorados.md`](../../sql-server/performance/sargability-e-indices-ignorados.md).

---

## Listas em `IN`

```csharp
// Dapper expande a lista automaticamente em @Ids1, @Ids2, ...
const string sql = "SELECT ClienteId, Nome FROM dbo.Cliente WHERE ClienteId IN @Ids";

var clientes = await conexao.QueryAsync<Cliente>(
    new CommandDefinition(sql, new { Ids = ids }, cancellationToken: cancellationToken));
```

Repare: **sem parênteses** em volta de `@Ids` — o Dapper os adiciona.

**Cuidado com listas grandes.** Cada tamanho de lista gera um SQL diferente e, portanto,
um plano diferente no cache. Cem tamanhos distintos, cem planos. Para listas grandes, use
*table-valued parameter*.

---

## Múltiplos conjuntos de resultados

Buscar tudo de uma vez elimina idas e voltas ao banco:

```csharp
const string sql = @"
    SELECT PedidoId, Data, Valor FROM dbo.Pedido  WHERE PedidoId = @Id;
    SELECT ItemId, Produto, Quantidade FROM dbo.PedidoItem WHERE PedidoId = @Id;
    SELECT PagamentoId, Valor, Data FROM dbo.Pagamento WHERE PedidoId = @Id;";

await using var multi = await conexao.QueryMultipleAsync(
    new CommandDefinition(sql, new { Id = pedidoId },
                          cancellationToken: cancellationToken));

var pedido     = await multi.ReadSingleAsync<Pedido>();
var itens      = (await multi.ReadAsync<PedidoItem>()).ToList();
var pagamentos = (await multi.ReadAsync<Pagamento>()).ToList();

pedido.Itens      = itens;
pedido.Pagamentos = pagamentos;
```

**A ordem de leitura precisa ser a mesma da ordem dos `SELECT`.**

---

## Mapeamento de múltiplas entidades (`splitOn`)

```csharp
const string sql = @"
    SELECT  p.PedidoId, p.Data, p.Valor,
            c.ClienteId, c.Nome, c.Documento
    FROM    dbo.Pedido  AS p
    JOIN    dbo.Cliente AS c ON c.ClienteId = p.ClienteId
    WHERE   p.Data >= @DataInicial;";

var pedidos = await conexao.QueryAsync<Pedido, Cliente, Pedido>(
    sql,
    map: (pedido, cliente) =>
    {
        pedido.Cliente = cliente;
        return pedido;
    },
    param: new { DataInicial = dataInicial },
    splitOn: "ClienteId");     // coluna onde comeca a segunda entidade
```

`splitOn` indica onde o Dapper deve "cortar" as colunas. O padrão é `Id`; se as suas
chaves têm outro nome, informe. Para três entidades, separe por vírgula:
`splitOn: "ClienteId,EnderecoId"`.

---

## Transações

```csharp
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(cancellationToken).ConfigureAwait(false);

await using var transacao = (SqlTransaction)await conexao
    .BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

try
{
    var pedidoId = await conexao.ExecuteScalarAsync<int>(new CommandDefinition(
        @"INSERT INTO dbo.Pedido (ClienteId, Data, Valor)
          OUTPUT INSERTED.PedidoId
          VALUES (@ClienteId, @Data, @Valor);",
        pedido, transacao, cancellationToken: cancellationToken));

    // Uma unica chamada, varias linhas: o Dapper repete o comando por item
    await conexao.ExecuteAsync(new CommandDefinition(
        @"INSERT INTO dbo.PedidoItem (PedidoId, Produto, Quantidade)
          VALUES (@PedidoId, @Produto, @Quantidade);",
        itens.Select(i => new { PedidoId = pedidoId, i.Produto, i.Quantidade }),
        transacao, cancellationToken: cancellationToken));

    await transacao.CommitAsync(cancellationToken).ConfigureAwait(false);
}
catch
{
    await transacao.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
    throw;
}
```

**A transação precisa ser passada em cada comando.** Esquecer em um deles faz aquele
comando rodar fora da transação — e o erro passa despercebido até o dia do rollback.

`OUTPUT INSERTED.PedidoId` é preferível a `SCOPE_IDENTITY()`: funciona com múltiplas
linhas e não depende de escopo.

---

## Inserção em massa

Passar uma coleção para `ExecuteAsync` faz o Dapper repetir o comando **uma vez por item**.
Para dezenas de linhas, tudo bem. Para milhares, é lento.

```csharp
// ✅ Para volume alto, use SqlBulkCopy
using var bulk = new SqlBulkCopy(conexao, SqlBulkCopyOptions.Default, transacao)
{
    DestinationTableName = "dbo.PedidoItem",
    BatchSize = 5000,
    BulkCopyTimeout = 120
};

bulk.ColumnMappings.Add(nameof(PedidoItem.PedidoId),   "PedidoId");
bulk.ColumnMappings.Add(nameof(PedidoItem.Produto),    "Produto");
bulk.ColumnMappings.Add(nameof(PedidoItem.Quantidade), "Quantidade");

await bulk.WriteToServerAsync(tabelaDeItens, cancellationToken);
```

Sempre declare `ColumnMappings`: sem eles, o mapeamento é posicional e uma coluna nova na
tabela quebra a carga em silêncio.

---

## Stored procedures

```csharp
var parametros = new DynamicParameters();
parametros.Add("@ClienteId", clienteId, DbType.Int32);
parametros.Add("@Total", dbType: DbType.Decimal, direction: ParameterDirection.Output);
parametros.Add("@Retorno", dbType: DbType.Int32, direction: ParameterDirection.ReturnValue);

var pedidos = await conexao.QueryAsync<Pedido>(new CommandDefinition(
    "dbo.usp_ObterPedidosPorCliente",
    parametros,
    commandType: CommandType.StoredProcedure,
    commandTimeout: 60,
    cancellationToken: cancellationToken));

var total   = parametros.Get<decimal>("@Total");
var retorno = parametros.Get<int>("@Retorno");
```

---

## Cuidados de performance

| Cuidado | Detalhe |
|---|---|
| **`buffered: false` para resultados enormes** | Por padrão o Dapper materializa tudo em memória. Com `buffered: false` ele transmite conforme você itera — mas a conexão fica ocupada durante a iteração |
| **`SELECT *` é pior aqui** | Você escreve o SQL: nomeie as colunas. Colunas a mais trafegam, alocam e podem impedir um índice de cobrir a consulta |
| **Paginação sempre** | `OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY` com `ORDER BY` determinístico |
| **Sem `N+1`** | Uma consulta em laço é `N+1` tanto no Dapper quanto no EF. Use `QueryMultiple` ou `JOIN` |
| **`CommandTimeout` sempre** | Veja [`../ado-net/timeout-de-comando-vs-conexao.md`](../ado-net/timeout-de-comando-vs-conexao.md) |

---

## Segurança

```csharp
// ❌ SQL INJECTION
var sql = $"SELECT * FROM dbo.Cliente WHERE Nome LIKE '%{termo}%'";

// ✅
const string sql = "SELECT ClienteId, Nome FROM dbo.Cliente WHERE Nome LIKE @Termo";
var clientes = await conexao.QueryAsync<Cliente>(
    new CommandDefinition(sql, new { Termo = "%" + termo + "%" },
                          cancellationToken: cancellationToken));
```

O curinga entra no **valor** do parâmetro, nunca no texto do SQL.

Quando parte do SQL precisa ser dinâmica — nome de coluna de ordenação, por exemplo — nunca
concatene a entrada do usuário. Valide contra uma lista fechada de valores permitidos.

---

## Checklist

- [ ] Todo parâmetro passa por objeto anônimo ou `DynamicParameters`, nunca concatenação.
- [ ] `DbType.AnsiString` para colunas `VARCHAR`, com tamanho.
- [ ] `CommandDefinition` com `CancellationToken` e `commandTimeout`.
- [ ] Colunas nomeadas no `SELECT`.
- [ ] Transação passada em **todos** os comandos do bloco.
- [ ] `SqlBulkCopy` para volume alto, com `ColumnMappings`.
- [ ] Sem consulta dentro de laço.
- [ ] `QuerySingleOrDefault` onde o resultado deve ser único.

## Referências

- [Dapper — repositório oficial](https://github.com/DapperLib/Dapper)
- [`SqlBulkCopy`](https://learn.microsoft.com/pt-br/dotnet/api/microsoft.data.sqlclient.sqlbulkcopy)
- [`OFFSET`/`FETCH`](https://learn.microsoft.com/pt-br/sql/t-sql/queries/select-order-by-clause-transact-sql)

---

**Criado por Fábio Cerqueira**
