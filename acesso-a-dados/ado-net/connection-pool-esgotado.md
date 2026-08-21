# "Timeout expired" ao abrir conexão — connection pool esgotado

> A mensagem culpa o banco. O banco quase nunca é o culpado. Este erro significa que a
> **aplicação** não devolveu conexões ao pool.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Aumentar `Max Pool Size` esconde o defeito e adia a queda |

---

## A mensagem

```text
System.InvalidOperationException: Timeout expired. The timeout period elapsed prior to
obtaining a connection from the pool. This may have occurred because all pooled
connections were in use and max pool size was reached.
```

Leia a segunda frase com atenção: **todas as conexões do pool estavam em uso**. Não é o SQL
Server que está lento nem indisponível — é a aplicação que não devolveu o que pegou
emprestado.

---

## Como o pool funciona

Abrir uma conexão TCP com o SQL Server, autenticar e negociar TLS custa caro. Por isso o
driver mantém um **pool** por connection string:

- `new SqlConnection(...)` + `Open()` → pega uma conexão **do pool**;
- `Dispose()`/`Close()` → **devolve** ao pool (não fecha o socket);
- se o pool está cheio e todas ocupadas, `Open()` **espera** até `Connect Timeout` e então
  lança o erro acima;
- o padrão de `Max Pool Size` é **100**;
- connection strings diferentes, mesmo por um espaço, geram **pools separados**.

---

## As cinco causas, em ordem de frequência

### 1. Conexão sem `Dispose` (a campeã)

```csharp
// ❌ Se ExecuteReader lancar, a conexao NUNCA volta ao pool
var conexao = new SqlConnection(_connectionString);
conexao.Open();
var comando = new SqlCommand(sql, conexao);
var leitor = comando.ExecuteReader();
// ...
conexao.Close();   // nao executa em caso de excecao

// ✅
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(cancellationToken);
```

Cada exceção vaza uma conexão. Cem exceções depois, o pool acabou. Por isso o sintoma
apareceu "do nada": provavelmente começou com um erro intermitente em outro ponto.

### 2. `DataReader` não fechado

Um `SqlDataReader` aberto mantém a conexão **ocupada**, mesmo que você já tenha lido tudo.

```csharp
// ❌ O leitor segura a conexao ate ser coletado pelo GC
var leitor = comando.ExecuteReader();

// ✅
await using var leitor = await comando.ExecuteReaderAsync(cancellationToken);
```

### 3. Conexão mantida aberta durante trabalho longo

```csharp
// ❌ A conexao fica ocupada durante a chamada HTTP
await using var conexao = new SqlConnection(_connectionString);
await conexao.OpenAsync(ct);

var dados = await LerDoBancoAsync(conexao, ct);
await _http.PostAsJsonAsync(url, dados, ct);      // <-- segurando a conexao
await GravarNoBancoAsync(conexao, dados, ct);

// ✅ Abra, use, devolva. Abra de novo se precisar.
List<Registro> dados;
await using (var conexao = new SqlConnection(_connectionString))
{
    await conexao.OpenAsync(ct);
    dados = await LerDoBancoAsync(conexao, ct);
}

await _http.PostAsJsonAsync(url, dados, ct);

await using (var conexao = new SqlConnection(_connectionString))
{
    await conexao.OpenAsync(ct);
    await GravarNoBancoAsync(conexao, dados, ct);
}
```

Abrir a conexão duas vezes é barato — o pool cuida disso. Segurá-la por segundos, não.

### 4. `DbContext` do EF com tempo de vida errado

Um `DbContext` registrado como **singleton** (em vez de *scoped*) mantém a conexão e
acumula rastreamento de entidades indefinidamente.

```csharp
// ❌
builder.Services.AddSingleton<MeuDbContext>();

// ✅ Um contexto por requisicao
builder.Services.AddDbContext<MeuDbContext>(options =>
    options.UseSqlServer(connectionString));
```

### 5. Queries lentas segurando conexões

Se cada query leva 10 segundos e chegam 20 requisições por segundo, o pool esgota mesmo
sem nenhum vazamento. Aqui o problema é **de banco**, e a correção está em
[`../../sql-server/performance/`](../../sql-server/performance/).

Esta é a única das cinco causas em que aumentar o pool ajuda — e ainda assim só
temporariamente.

---

## Diagnóstico

### Do lado do banco

```sql
/* Quantas conexoes cada aplicacao mantem, e quantas estao realmente ativas.
   Muitas sessoes 'sleeping' de uma unica aplicacao = vazamento. */
SELECT
    programa             = ISNULL(s.program_name, '(nao informado)'),
    host                 = s.host_name,
    s.login_name,
    total                = COUNT(*),
    ativas               = SUM(CASE WHEN s.status IN ('running','runnable') THEN 1 ELSE 0 END),
    ociosas              = SUM(CASE WHEN s.status = 'sleeping' THEN 1 ELSE 0 END),
    com_transacao_aberta = SUM(CASE WHEN s.open_transaction_count > 0 THEN 1 ELSE 0 END),
    mais_antiga          = MIN(s.login_time)
FROM sys.dm_exec_sessions AS s
WHERE s.is_user_process = 1
GROUP BY s.program_name, s.host_name, s.login_name
ORDER BY total DESC;
```

Use [`../../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql`](../../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql)
para a visão completa.

Se todas as conexões chegam como `.Net SqlClient Data Provider`, configure
`Application Name` — sem isso não dá para saber qual sistema está vazando.

### Do lado da aplicação (.NET moderno)

```bash
dotnet-counters monitor --process-id <PID> --counters Microsoft.Data.SqlClient.EventSource
```

Acompanhe as contagens de conexões ativas e livres. Conexões ativas subindo e nunca
voltando é a assinatura do vazamento.

---

## O que **não** fazer

```text
Max Pool Size=500
```

Aumentar o pool porque "está esgotando" apenas adia a queda — agora com 500 sessões no SQL
Server, cada uma consumindo memória e worker thread. Em casos ruins, isso transforma um
problema de uma aplicação em um problema da instância inteira, com espera `THREADPOOL`.

Ajustar `Max Pool Size` é legítimo quando você **mediu** a concorrência real e concluiu que
100 é pouco. Não é legítimo como resposta a um vazamento.

---

## Sobre `Pooling=false`

```text
Pooling=False
```

Desliga o pool: cada `Open()` cria uma conexão TCP nova. O erro de pool desaparece — e a
latência de cada operação aumenta muito, além de o servidor passar a acumular portas em
`TIME_WAIT`, o mesmo problema descrito em
[`../../dotnet/httpclient/httpclient-uso-correto.md`](../../dotnet/httpclient/httpclient-uso-correto.md).

Nunca use em produção. É útil apenas para isolar o comportamento durante uma investigação.

---

## Checklist

- [ ] Toda `SqlConnection` em `using`/`await using`.
- [ ] Todo `SqlDataReader` em `using`/`await using`.
- [ ] Nenhuma conexão mantida aberta durante chamada HTTP ou processamento longo.
- [ ] `DbContext` registrado como *scoped*, nunca singleton.
- [ ] `Application Name` na connection string.
- [ ] Connection string idêntica em todos os pontos (pools separados por diferença de texto).
- [ ] Queries lentas investigadas antes de mexer no tamanho do pool.

## Referências

- [Pooling de conexão no SQL Server](https://learn.microsoft.com/pt-br/sql/connect/ado-net/sql-server-connection-pooling)
- [Sintaxe de connection string](https://learn.microsoft.com/pt-br/sql/connect/ado-net/connection-string-syntax)

---

**Criado por Fábio Cerqueira**
