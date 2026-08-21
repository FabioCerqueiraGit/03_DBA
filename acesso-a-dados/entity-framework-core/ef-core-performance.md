# Entity Framework Core — performance e armadilhas

> O EF Core é produtivo e gera SQL razoável na maior parte do tempo. Os problemas nascem de
> um punhado de padrões que parecem inofensivos no código e viram centenas de queries em
> produção.

| | |
|---|---|
| **Compatibilidade** | EF Core 6+ · recursos marcados por versão quando relevante |
| **Pacotes** | `Microsoft.EntityFrameworkCore.SqlServer` |
| **Impacto** | Alto. `N+1` é a causa mais comum de "o banco está lento" com CPU pulverizada |

---

## Antes de tudo: veja o SQL gerado

Não se otimiza o que não se vê. Duas formas:

```csharp
// 1. Inspecionar a query especifica (EF Core 5+)
var sql = context.Pedidos
                 .Where(p => p.ClienteId == clienteId)
                 .ToQueryString();

_logger.LogDebug("SQL gerado: {Sql}", sql);
```

```csharp
// 2. Registrar tudo em desenvolvimento
options.UseSqlServer(connectionString)
       .LogTo(Console.WriteLine, LogLevel.Information)
       .EnableSensitiveDataLogging()   // mostra os VALORES dos parametros
       .EnableDetailedErrors();
```

> **`EnableSensitiveDataLogging` nunca vai para produção.** Ele grava os valores dos
> parâmetros no log — CPF, senha, token, o que passar por ali. Deixe-o condicionado ao
> ambiente de desenvolvimento.

Do lado do banco, [`../../sql-server/performance/queries-que-mais-consomem-cpu.sql`](../../sql-server/performance/queries-que-mais-consomem-cpu.sql)
mostra o que a aplicação realmente está enviando.

---

## 1. `N+1` — o clássico

```csharp
// ❌ 1 query para os pedidos + 1 query POR PEDIDO para o cliente
var pedidos = await context.Pedidos.Take(100).ToListAsync(ct);

foreach (var pedido in pedidos)
{
    // Lazy loading dispara uma query aqui, 100 vezes
    Console.WriteLine(pedido.Cliente.Nome);
}
```

No SQL Server isso aparece como **centenas de execuções de uma query barata** — o padrão
que o [roteiro de diagnóstico](../../sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md)
chama de "problema de volume de chamadas, não de query".

```csharp
// ✅ Include: uma query com JOIN
var pedidos = await context.Pedidos
    .Include(p => p.Cliente)
    .Take(100)
    .ToListAsync(ct);

// ✅✅ Melhor ainda: projete so o que precisa
var pedidos = await context.Pedidos
    .Select(p => new PedidoResumo(p.PedidoId, p.Data, p.Valor, p.Cliente.Nome))
    .Take(100)
    .ToListAsync(ct);
```

A projeção com `Select` é quase sempre a melhor opção para leitura: gera `SELECT` apenas
das colunas usadas, não rastreia entidades e permite que um índice cubra a consulta.

> Desligue *lazy loading* (`UseLazyLoadingProxies`) a menos que você tenha um motivo
> concreto. Ele torna o `N+1` invisível no código.

---

## 2. Explosão cartesiana com múltiplos `Include`

```csharp
// ❌ Um pedido com 20 itens e 5 pagamentos retorna 100 linhas,
//    repetindo os dados do pedido em cada uma
var pedidos = await context.Pedidos
    .Include(p => p.Itens)
    .Include(p => p.Pagamentos)
    .ToListAsync(ct);
```

O EF Core monta um único `JOIN` e o produto cartesiano das coleções explode o volume
trafegado. Com três coleções, o efeito é multiplicativo.

```csharp
// ✅ AsSplitQuery (EF Core 5+): uma query por colecao, sem produto cartesiano
var pedidos = await context.Pedidos
    .Include(p => p.Itens)
    .Include(p => p.Pagamentos)
    .AsSplitQuery()
    .ToListAsync(ct);
```

**Contrapartida:** com *split query*, as consultas não são executadas na mesma transação
por padrão, então os dados podem ser inconsistentes entre si se houver escrita concorrente.
Avalie o caso.

---

## 3. Rastreamento desnecessário

Por padrão, o `DbContext` guarda um *snapshot* de cada entidade carregada para detectar
mudanças. Em consulta de leitura pura, isso é memória e CPU jogados fora.

```csharp
// ✅ Leitura sem rastreamento
var pedidos = await context.Pedidos
    .AsNoTracking()
    .Where(p => p.Data >= dataInicial)
    .ToListAsync(ct);
```

```csharp
// Ou como padrao do contexto inteiro, para um contexto so de leitura
options.UseQueryTrackingBehavior(QueryTrackingBehavior.NoTracking);
```

Se a consulta retorna a mesma entidade várias vezes e você precisa que sejam a **mesma
instância**, use `AsNoTrackingWithIdentityResolution()` (EF Core 5+).

> Uma projeção com `Select` para um tipo que não é entidade **já não rastreia nada** —
> `AsNoTracking` nesse caso é redundante.

---

## 4. Filtrar depois de materializar

```csharp
// ❌ Traz a tabela INTEIRA para a memoria e filtra em C#
var pedidos = (await context.Pedidos.ToListAsync(ct))
    .Where(p => p.Valor > 1000)
    .ToList();

// ✅ O filtro vai para o banco
var pedidos = await context.Pedidos
    .Where(p => p.Valor > 1000)
    .ToListAsync(ct);
```

O `ToListAsync` **executa** a consulta. Tudo que vem depois dele roda em memória.

A partir do EF Core 3.0, a avaliação no cliente de expressões do `Where` deixou de
acontecer silenciosamente: o EF **lança exceção** quando não consegue traduzir. Isso é uma
melhoria — antes, uma expressão não traduzível trazia a tabela inteira sem avisar.

---

## 5. Paginação ausente ou instável

```csharp
// ❌ Sem limite: um dia a tabela cresce e a tela morre
var todos = await context.Pedidos.ToListAsync(ct);

// ❌ Skip/Take sem ORDER BY determinístico: a ordem nao e garantida,
//    e a pagina 2 pode repetir itens da pagina 1
var pagina = await context.Pedidos.Skip(20).Take(20).ToListAsync(ct);

// ✅
var pagina = await context.Pedidos
    .OrderByDescending(p => p.Data)
    .ThenBy(p => p.PedidoId)          // desempate estavel
    .Skip((numeroDaPagina - 1) * tamanho)
    .Take(tamanho)
    .AsNoTracking()
    .ToListAsync(ct);
```

Para volumes grandes, `Skip` fica caro nas páginas finais — o banco precisa percorrer tudo
que foi pulado. Nesses casos, use **paginação por chave** ("me dê os 20 seguintes ao
`PedidoId` X").

---

## 6. Atualização e exclusão em massa

```csharp
// ❌ Carrega 100 mil entidades para a memoria e emite 100 mil UPDATEs
var antigos = await context.Pedidos
    .Where(p => p.Data < limite)
    .ToListAsync(ct);

foreach (var p in antigos) p.Status = "ARQUIVADO";
await context.SaveChangesAsync(ct);
```

```csharp
// ✅ EF Core 7+: um unico UPDATE no banco, sem materializar nada
await context.Pedidos
    .Where(p => p.Data < limite)
    .ExecuteUpdateAsync(s => s.SetProperty(p => p.Status, "ARQUIVADO"), ct);

// ✅ EF Core 7+: um unico DELETE
await context.Pedidos
    .Where(p => p.Data < limite)
    .ExecuteDeleteAsync(ct);
```

**Atenção:** `ExecuteUpdate` e `ExecuteDelete` vão direto ao banco e **não passam pelo
rastreamento de mudanças**. Entidades já carregadas no contexto ficam desatualizadas, e
interceptadores baseados em `SaveChanges` não são acionados.

Um `DELETE` de milhões de linhas em uma única instrução gera transaction log enorme e
escalonamento de lock. Processe em lotes:

```csharp
int afetadas;
do
{
    afetadas = await context.Pedidos
        .Where(p => p.Data < limite)
        .Take(5000)
        .ExecuteDeleteAsync(ct);
}
while (afetadas > 0);
```

Em EF Core 6 ou anterior, use SQL direto (`ExecuteSqlInterpolatedAsync`) ou Dapper.

---

## 7. Tempo de vida do `DbContext`

```csharp
// ✅ Um contexto por requisicao (scoped)
builder.Services.AddDbContext<MeuDbContext>(options =>
    options.UseSqlServer(connectionString));

// ✅ Pooling: reaproveita instancias, util em API de alto volume
builder.Services.AddDbContextPool<MeuDbContext>(options =>
    options.UseSqlServer(connectionString));
```

**Nunca registre o `DbContext` como singleton.** Ele não é thread-safe, acumula
rastreamento indefinidamente e segura conexão. Veja
[`../ado-net/connection-pool-esgotado.md`](../ado-net/connection-pool-esgotado.md).

Pelo mesmo motivo, **nunca dispare duas queries em paralelo no mesmo contexto**:

```csharp
// ❌ InvalidOperationException: A second operation was started on this context
var t1 = context.Pedidos.ToListAsync(ct);
var t2 = context.Clientes.ToListAsync(ct);
await Task.WhenAll(t1, t2);

// ✅ Um contexto por operacao paralela
await using var ctx1 = await _factory.CreateDbContextAsync(ct);
await using var ctx2 = await _factory.CreateDbContextAsync(ct);

var t1 = ctx1.Pedidos.ToListAsync(ct);
var t2 = ctx2.Clientes.ToListAsync(ct);
await Task.WhenAll(t1, t2);
```

`AddDbContextFactory` fornece a fábrica usada acima.

---

## 8. Consultas compiladas

Para uma consulta executada milhares de vezes por minuto, o custo de traduzir a árvore de
expressão passa a pesar:

```csharp
private static readonly Func<MeuDbContext, int, CancellationToken, Task<Pedido?>>
    ObterPedidoCompilado = EF.CompileAsyncQuery(
        (MeuDbContext ctx, int id, CancellationToken ct) =>
            ctx.Pedidos.FirstOrDefault(p => p.PedidoId == id));

// Uso
var pedido = await ObterPedidoCompilado(context, id, cancellationToken);
```

Ganho real, mas só em caminho de altíssima frequência. Não é a primeira otimização a
tentar — corrija `N+1`, rastreamento e projeção antes.

---

## 9. Resiliência a erros transitórios

```csharp
options.UseSqlServer(connectionString, sql =>
{
    sql.EnableRetryOnFailure(
        maxRetryCount: 3,
        maxRetryDelay: TimeSpan.FromSeconds(10),
        errorNumbersToAdd: null);

    sql.CommandTimeout(30);
});
```

**Cuidado:** com `EnableRetryOnFailure` ativo, transações iniciadas manualmente com
`BeginTransaction` precisam ser executadas dentro de uma *execution strategy* — caso
contrário o EF lança exceção, porque não pode repetir uma transação parcialmente aplicada:

```csharp
var estrategia = context.Database.CreateExecutionStrategy();

await estrategia.ExecuteAsync(async () =>
{
    await using var transacao = await context.Database.BeginTransactionAsync(ct);

    // ... operacoes ...

    await context.SaveChangesAsync(ct);
    await transacao.CommitAsync(ct);
});
```

---

## Migrations em produção

```csharp
// ❌ Nunca em producao: sem controle, sem revisao, sem rollback
await context.Database.MigrateAsync();
```

`MigrateAsync` na inicialização parece prático e cria três problemas: aplica alteração de
esquema sem revisão, disputa entre instâncias quando há mais de um nó, e nenhum plano de
reverter.

```bash
# ✅ Gerar o script, revisar, aplicar de forma controlada
dotnet ef migrations script <MigrationAnterior> <MigrationAlvo> --idempotent --output migracao.sql
```

O script idempotente pode ser revisado, versionado, testado em homologação e aplicado na
janela — com um plano de rollback escrito antes.

---

## Checklist

- [ ] SQL gerado inspecionado em desenvolvimento (`ToQueryString` ou `LogTo`).
- [ ] `EnableSensitiveDataLogging` **fora** de produção.
- [ ] Nenhuma consulta dentro de laço.
- [ ] Lazy loading desligado, ou usado com plena consciência.
- [ ] `AsNoTracking` em leitura, ou projeção com `Select`.
- [ ] `AsSplitQuery` quando há múltiplos `Include` de coleção.
- [ ] Toda listagem paginada, com `ORDER BY` determinístico.
- [ ] Operações em massa com `ExecuteUpdate`/`ExecuteDelete`, em lotes.
- [ ] `DbContext` *scoped*; nenhuma query paralela no mesmo contexto.
- [ ] `CommandTimeout` e `EnableRetryOnFailure` configurados.
- [ ] Migrations aplicadas por script revisado, não por `MigrateAsync`.

## Referências

- [Desempenho no EF Core](https://learn.microsoft.com/pt-br/ef/core/performance/)
- [Consultas eficientes](https://learn.microsoft.com/pt-br/ef/core/performance/efficient-querying)
- [Consultas divididas](https://learn.microsoft.com/pt-br/ef/core/querying/single-split-queries)
- [`ExecuteUpdate` e `ExecuteDelete`](https://learn.microsoft.com/pt-br/ef/core/saving/execute-insert-update-delete)
- [Resiliência de conexão](https://learn.microsoft.com/pt-br/ef/core/miscellaneous/connection-resiliency)

---

**Criado por Fábio Cerqueira**
