# `CommandTimeout` versus `Connect Timeout` — e por que sua query "para em 30 segundos"

> Dois parâmetros com nomes parecidos, propósitos completamente diferentes. Confundi-los é
> a raiz de metade dos chamados de "timeout no banco".

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Aumentar o timeout sem entender a causa piora o comportamento sob carga |

---

## Os dois parâmetros

| | `Connect Timeout` | `CommandTimeout` |
|---|---|---|
| **Onde se define** | Connection string | Objeto `SqlCommand` (ou o ORM) |
| **O que cronometra** | Abrir a conexão | Executar o comando |
| **Padrão** | 15 segundos | **30 segundos** |
| **Erro típico** | `Timeout expired. The timeout period elapsed prior to obtaining a connection from the pool` | `Timeout expired. The timeout period elapsed prior to completion of the operation` |
| **Número do erro** | — | `-2` |

Se o timeout ocorre sempre por volta dos **30 segundos**, é `CommandTimeout` no padrão. Se
ocorre ao **abrir** a conexão, veja
[`connection-pool-esgotado.md`](connection-pool-esgotado.md).

---

## `CommandTimeout`

```csharp
await using var comando = new SqlCommand(sql, conexao);

// Sempre defina conscientemente. Zero = sem limite -- perigoso.
comando.CommandTimeout = 30;
```

```csharp
// Dapper
var pedidos = await conexao.QueryAsync<Pedido>(
    sql, parametros, commandTimeout: 30);

// EF Core -- por contexto
options.UseSqlServer(connectionString,
    sql => sql.CommandTimeout(30));

// EF Core -- pontualmente
context.Database.SetCommandTimeout(TimeSpan.FromSeconds(120));

// EF6
context.Database.CommandTimeout = 30;
```

> `CommandTimeout = 0` significa **esperar para sempre**. Em produção, isso transforma uma
> query travada em uma conexão eternamente ocupada, e depois em pool esgotado. Se um
> processo realmente precisa de horas, ele não deveria estar em um caminho de requisição.

---

## O que acontece quando o `CommandTimeout` estoura

Este é o ponto que quase ninguém sabe, e que causa incidentes de bloqueio:

1. o cliente **desiste** e envia um comando de cancelamento (*attention*) ao SQL Server;
2. o SQL Server aborta a execução da instrução;
3. **a transação continua aberta.**

Se a aplicação não tratar a exceção com rollback explícito, fica uma transação aberta
segurando locks — e o próximo comando na mesma conexão continua dentro dela.

Esta é uma das origens mais frequentes das sessões `sleeping` com
`open_transaction_count > 0` que aparecem em
[`../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql).

```csharp
// ✅ Rollback garantido mesmo em timeout
await using var transacao = (SqlTransaction)await conexao
    .BeginTransactionAsync(cancellationToken).ConfigureAwait(false);

try
{
    await ExecutarAsync(conexao, transacao, cancellationToken).ConfigureAwait(false);
    await transacao.CommitAsync(cancellationToken).ConfigureAwait(false);
}
catch (SqlException ex) when (ex.Number == -2)
{
    // CommandTimeout. O rollback NAO pode depender do token cancelado.
    await transacao.RollbackAsync(CancellationToken.None).ConfigureAwait(false);

    _logger.LogWarning(ex, "Timeout ao executar a operacao {Operacao}", nomeDaOperacao);
    throw;
}
catch
{
    await transacao.RollbackAsync(CancellationToken.None).ConfigureAwait(false);
    throw;
}
```

O `await using` na transação já faz rollback no descarte, mas o `catch` explícito garante o
momento e permite registrar o log com contexto.

---

## Roteiro de diagnóstico

### Passo 1 — Confirmar qual timeout estourou

| Mensagem contém | Timeout |
|---|---|
| `prior to obtaining a connection from the pool` | Pool esgotado |
| `prior to completion of the operation` | `CommandTimeout` |
| `A network-related or instance-specific error` | Não é timeout: conectividade, DNS, firewall ou instância fora |

### Passo 2 — Verificar se é bloqueio

A query que roda em 200 ms normalmente e estoura 30 segundos de vez em quando quase sempre
está **bloqueada**, não lenta.

Rode, durante a ocorrência:
[`../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql)

### Passo 3 — Verificar se é a query

Se a query é lenta **sempre**, o problema é de plano:
[`../../sql-server/performance/queries-mais-lentas-por-duracao.sql`](../../sql-server/performance/queries-mais-lentas-por-duracao.sql)

### Passo 4 — Verificar se é parameter sniffing

Se é rápida para uns parâmetros e estoura para outros:
[`../../sql-server/performance/parameter-sniffing.md`](../../sql-server/performance/parameter-sniffing.md)

---

## Como escolher o valor

| Tipo de operação | Faixa de partida |
|---|---|
| Consulta de tela, por chave | 5 a 15 s |
| Consulta de listagem paginada | 15 a 30 s |
| Relatório | 60 a 120 s — e avalie tornar assíncrono |
| Carga ou ETL | Minutos, **fora** do caminho de requisição |

Regra: o timeout deve ser **um pouco acima do p99 medido**, não um número grande escolhido
para "não dar erro". Um timeout justo é um detector de problema; um timeout enorme é um
amplificador de incidente.

### O antipadrão

```csharp
// ❌ "Deu timeout, coloca 0"
comando.CommandTimeout = 0;
```

Sob carga: a conexão fica ocupada indefinidamente → o pool esgota → **toda** a aplicação
para, não só a operação lenta. E, se houver transação aberta, os locks ficam retidos o
tempo todo.

---

## Timeout na aplicação versus `LOCK_TIMEOUT` no banco

São mecanismos diferentes:

```sql
/* Do lado do banco: desistir apos 10 segundos esperando um LOCK.
   Vale apenas para a sessao atual. */
SET LOCK_TIMEOUT 10000;
```

Com `LOCK_TIMEOUT`, o SQL Server lança o erro **1222** (`Lock request time out period
exceeded`) rapidamente, em vez de a aplicação esperar o `CommandTimeout` inteiro. É útil em
processos de baixa prioridade que não devem ficar presos atrás de um bloqueio.

Não confunda 1222 com deadlock (1205): 1222 é espera longa; 1205 é ciclo. Veja
[`../../sql-server/troubleshooting/investigar-deadlocks.md`](../../sql-server/troubleshooting/investigar-deadlocks.md).

---

## Checklist

- [ ] `CommandTimeout` definido explicitamente, nunca deixado no padrão por descuido.
- [ ] `CommandTimeout = 0` não existe no código de produção.
- [ ] Timeout de comando calibrado pelo p99 medido.
- [ ] Rollback explícito no tratamento do erro `-2`.
- [ ] Rollback usa `CancellationToken.None`.
- [ ] Antes de aumentar o timeout, verificou-se bloqueio e plano.

## Referências

- [`SqlCommand.CommandTimeout`](https://learn.microsoft.com/pt-br/dotnet/api/microsoft.data.sqlclient.sqlcommand.commandtimeout)
- [`SET LOCK_TIMEOUT`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/set-lock-timeout-transact-sql)
- [Entender e resolver problemas de bloqueio](https://learn.microsoft.com/pt-br/troubleshoot/sql/database-engine/performance/understand-resolve-blocking)

---

**Criado por Fábio Cerqueira**
