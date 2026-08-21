# ADO.NET — fundamentos seguros

> Todo acesso a dados em .NET termina em ADO.NET. Dapper, EF Core e EF6 são camadas por
> cima dele. Entender o que acontece aqui é o que permite diagnosticar o que acontece lá em
> cima.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Pacotes** | `Microsoft.Data.SqlClient` (recomendado) ou `System.Data.SqlClient` (legado) |
| **Impacto** | Erros aqui viram SQL Injection, vazamento de conexão ou plano ruim |

---

## Qual driver usar

| Pacote | Situação |
|---|---|
| **`Microsoft.Data.SqlClient`** | Driver ativo. Recebe recursos novos (Always Encrypted com enclaves, autenticação do Entra ID, melhorias de TLS). **Use este em código novo** |
| `System.Data.SqlClient` | Legado, em manutenção. Presente por padrão no .NET Framework |

A migração costuma ser só trocar o `using` — os tipos têm os mesmos nomes. Mas há uma
diferença de comportamento que derruba sistemas em produção:

> **A partir da versão 4.0 de `Microsoft.Data.SqlClient`, o padrão de `Encrypt` passou a ser
> `True`.** Se o servidor usa certificado autoassinado, a conexão falha com
> *"A connection was successfully established with the server, but then an error occurred
> during the login process"* ou erro de cadeia de certificação.

A correção certa é instalar um certificado confiável no servidor. A correção rápida — e
conscientemente insegura — é `TrustServerCertificate=True` na connection string. Se usar,
documente por quê e crie um item para resolver.

---

## Connection string

```text
Server=<SERVIDOR>;
Database=<BANCO>;
User Id=<USUARIO>;
Password=<SENHA>;
Application Name=<NOME-DO-SISTEMA>;
Encrypt=True;
Connect Timeout=15;
Max Pool Size=100;
MultipleActiveResultSets=False;
```

| Parâmetro | Por que importa |
|---|---|
| **`Application Name`** | Aparece em `program_name` nas DMVs. **Sem isso, nenhum diagnóstico de banco consegue apontar qual sistema causou o problema.** É o ajuste de observabilidade mais barato que existe |
| `Connect Timeout` | Tempo para **abrir** a conexão. Não confunda com `CommandTimeout` |
| `Max Pool Size` | Padrão 100. Aumentar sem entender a causa costuma esconder vazamento |
| `Encrypt` | Criptografia do canal |
| `MultipleActiveResultSets` | Permite vários `DataReader` abertos na mesma conexão. Habilite só se realmente precisar |

**Autenticação integrada** (`Integrated Security=True`) elimina a senha da connection
string — prefira-a sempre que a topologia permitir. No Azure, identidade gerenciada.

Nunca versione senha. Veja [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md).

---

## Conexão: sempre `using`

```csharp
// ✅ O using devolve a conexao ao POOL (nao fecha o socket TCP)
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(cancellationToken).ConfigureAwait(false);

await using var comando = new SqlCommand(
    "SELECT PedidoId, Data, Valor FROM dbo.Pedido WHERE ClienteId = @ClienteId",
    conexao);

comando.Parameters.Add("@ClienteId", SqlDbType.Int).Value = clienteId;
comando.CommandTimeout = 30;

await using var leitor = await comando.ExecuteReaderAsync(cancellationToken)
                                      .ConfigureAwait(false);

var pedidos = new List<Pedido>();

while (await leitor.ReadAsync(cancellationToken).ConfigureAwait(false))
{
    pedidos.Add(new Pedido(
        Id:    leitor.GetInt32(0),
        Data:  leitor.GetDateTime(1),
        Valor: leitor.GetDecimal(2)));
}
```

> `await using` exige C# 8+ e `IAsyncDisposable`. Em .NET Framework, use `using` normal.

**Diferente de `HttpClient`, aqui o `using` é obrigatório.** `SqlConnection` é leve porque
o pool cuida da conexão real: `Dispose` devolve a conexão ao pool em vez de derrubar o
socket. Não chamar `Dispose` é exatamente o que esgota o pool.

Use índices posicionais (`GetInt32(0)`) em vez de `leitor["Coluna"]`: é mais rápido e a
coluna nomeada em `SELECT` já documenta a ordem. Para colunas anuláveis, teste
`IsDBNull` antes.

---

## Parametrização — duas razões, não uma

```csharp
// ❌ SQL INJECTION. Nao existe versao aceitavel disto.
var sql = $"SELECT * FROM dbo.Cliente WHERE Nome = '{nome}'";

// ✅
const string sql = "SELECT ClienteId, Nome FROM dbo.Cliente WHERE Nome = @Nome";
comando.Parameters.Add("@Nome", SqlDbType.VarChar, 100).Value = nome;
```

A segurança é a razão óbvia. A segunda razão é de **performance**: SQL concatenado gera um
plano de execução novo a cada valor diferente. Isso queima CPU no otimizador e incha o
cache de planos, despejando planos úteis.

O script
[`../../sql-server/performance/queries-que-mais-consomem-cpu.sql`](../../sql-server/performance/queries-que-mais-consomem-cpu.sql)
detecta esse padrão: dezenas de planos com o mesmo `query_hash`.

### `AddWithValue` — por que evitar

```csharp
// ❌ O tipo e inferido, e a inferencia costuma errar
comando.Parameters.AddWithValue("@Documento", documento);

// ✅ Tipo e tamanho explicitos, iguais aos da coluna
comando.Parameters.Add("@Documento", SqlDbType.VarChar, 20).Value = documento;
```

Para uma `string` do C#, `AddWithValue` infere **`NVARCHAR`**. Se a coluna for `VARCHAR`,
o SQL Server precisa converter — e, pelas regras de precedência de tipo, converte **o lado
da coluna**. O índice deixa de servir para busca e a query passa a varrer a tabela inteira.

Esse é um dos problemas de performance mais comuns e mais invisíveis em aplicações .NET.
No plano aparece como `CONVERT_IMPLICIT`. Detalhes em
[`../../sql-server/performance/sargability-e-indices-ignorados.md`](../../sql-server/performance/sargability-e-indices-ignorados.md).

O mesmo vale para tamanho: sem informar o tamanho, o `NVARCHAR` inferido varia conforme o
valor, gerando um plano diferente para cada tamanho de entrada.

### `IN` com lista de valores

```csharp
// ❌ Concatenar a lista: injecao + explosao de planos
var sql = $"SELECT ... WHERE ClienteId IN ({string.Join(",", ids)})";

// ✅ Parametros gerados dinamicamente (lista pequena)
var nomes = ids.Select((_, i) => "@id" + i).ToArray();
var sql = $"SELECT ClienteId, Nome FROM dbo.Cliente WHERE ClienteId IN ({string.Join(",", nomes)})";

for (var i = 0; i < ids.Count; i++)
    comando.Parameters.Add(nomes[i], SqlDbType.Int).Value = ids[i];
```

Para listas grandes (centenas de itens), a opção correta é **table-valued parameter**: um
tipo de tabela no banco recebe a lista de uma vez, com plano estável.

---

## Transações

```csharp
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(cancellationToken).ConfigureAwait(false);

await using var transacao = (SqlTransaction)await conexao
    .BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

try
{
    await using (var comando = new SqlCommand(sqlInsercao, conexao, transacao))
    {
        comando.Parameters.Add("@PedidoId", SqlDbType.Int).Value = pedidoId;
        await comando.ExecuteNonQueryAsync(cancellationToken).ConfigureAwait(false);
    }

    await transacao.CommitAsync(cancellationToken).ConfigureAwait(false);
}
catch
{
    await transacao.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
    throw;
}
```

### As três regras de transação

**1. Transação curta.** Cada milissegundo de transação aberta é um milissegundo de lock
segurado. Ver
[`../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql).

**2. Nunca chame serviço externo dentro de uma transação.**

```csharp
// ❌ A transacao fica aberta esperando a API responder.
//    Se a API travar, o banco fica bloqueado junto.
await using var transacao = await conexao.BeginTransactionAsync(ct);
await _http.PostAsJsonAsync(url, dados, ct);   // <-- aqui
await transacao.CommitAsync(ct);
```

Esta é a causa número um das "transações abertas e abandonadas" que aparecem em
[`encontrar-transacoes-abertas-longa-duracao.sql`](../../sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql).

**3. Rollback no `CancellationToken.None`.** Se o token já foi cancelado, um rollback que o
respeite falharia — e a transação ficaria aberta. O rollback precisa acontecer.

### `TransactionScope` — cuidado no legado

```csharp
using var escopo = new TransactionScope(
    TransactionScopeOption.Required,
    new TransactionOptions
    {
        IsolationLevel = System.Transactions.IsolationLevel.ReadCommitted,
        Timeout = TimeSpan.FromSeconds(30)
    },
    TransactionScopeAsyncFlowOption.Enabled);   // obrigatorio com async/await

// ... operacoes ...

escopo.Complete();   // sem isto, o Dispose faz ROLLBACK
```

Dois detalhes que geram incidente:

- **`TransactionScopeAsyncFlowOption.Enabled`** é obrigatório quando há `await` dentro do
  escopo. Sem ele, a continuação roda fora da transação;
- o padrão de `IsolationLevel` do `TransactionScope` é **`Serializable`**, não
  `ReadCommitted`. Isso causa bloqueio muito mais agressivo do que o esperado. Sempre
  informe o nível explicitamente.

Abrir mais de uma conexão dentro de um `TransactionScope` pode promover a transação para
distribuída (MSDTC), com custo e dependência de infraestrutura bem maiores.

---

## Exceções: transitório ou permanente

```csharp
catch (SqlException ex) when (EhTransitorio(ex.Number))
{
    // vale retry
}

private static bool EhTransitorio(int numero) => numero switch
{
    1205  => true,   // deadlock victim
    -2    => true,   // timeout
    1204  => true,   // sem recursos de lock
    701   => true,   // memoria insuficiente no servidor
    40197 => true,   // Azure SQL: erro de processamento, tente novamente
    40501 => true,   // Azure SQL: servico ocupado
    40613 => true,   // Azure SQL: banco indisponivel no momento
    49918 => true,   // Azure SQL: sem recursos para processar
    _     => false
};
```

Erros como 2627 (violação de chave primária), 547 (violação de constraint) e 208 (objeto
inexistente) são **permanentes**. Repetir não muda o resultado — só gasta tempo e polui o
log.

O retry de deadlock precisa de backoff **com jitter**; sem ele, as duas transações que
colidiram voltam no mesmo instante e colidem de novo. Veja
[`../../sql-server/troubleshooting/investigar-deadlocks.md`](../../sql-server/troubleshooting/investigar-deadlocks.md).

---

## Checklist

- [ ] `Microsoft.Data.SqlClient` em código novo.
- [ ] `Application Name` na connection string.
- [ ] Senha fora do código e fora do repositório.
- [ ] `using`/`await using` em toda `SqlConnection`, `SqlCommand` e `SqlDataReader`.
- [ ] **Zero** concatenação de valores em SQL.
- [ ] `Parameters.Add` com tipo e tamanho, nunca `AddWithValue`.
- [ ] `CommandTimeout` definido conscientemente.
- [ ] Métodos assíncronos (`OpenAsync`, `ExecuteReaderAsync`, `ReadAsync`) com
      `CancellationToken`.
- [ ] Transações curtas, sem chamada externa dentro.
- [ ] `TransactionScope` com `IsolationLevel` explícito e `AsyncFlowOption.Enabled`.
- [ ] Erros transitórios classificados e tratados com retry; permanentes, não.

## Referências

- [Visão geral do `Microsoft.Data.SqlClient`](https://learn.microsoft.com/pt-br/sql/connect/ado-net/microsoft-ado-net-sql-server)
- [Sintaxe de connection string](https://learn.microsoft.com/pt-br/sql/connect/ado-net/connection-string-syntax)
- [`SqlCommand.Parameters`](https://learn.microsoft.com/pt-br/dotnet/api/microsoft.data.sqlclient.sqlcommand.parameters)
- [`System.Transactions`](https://learn.microsoft.com/pt-br/dotnet/framework/data/transactions/)

---

**Criado por Fábio Cerqueira**
