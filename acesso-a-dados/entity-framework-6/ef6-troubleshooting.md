# Entity Framework 6 — troubleshooting de sistemas legados

> EF6 continua rodando em muito sistema que paga as contas. Este documento trata do que
> quebra nele, com as diferenças em relação ao EF Core marcadas — porque conselho de EF
> Core aplicado a EF6 costuma não funcionar.

| | |
|---|---|
| **Compatibilidade** | EF6 em .NET Framework 4.6.2+ (também roda em .NET Core 3.0+ via EF 6.3+) |
| **Impacto** | Alto: `N+1` por lazy loading é o padrão de fábrica |

---

## Diferenças que mais confundem

| | EF6 | EF Core |
|---|---|---|
| Namespace | `System.Data.Entity` | `Microsoft.EntityFrameworkCore` |
| **Lazy loading** | **Ligado por padrão** com propriedades `virtual` | Desligado, exige pacote de proxies |
| Ver o SQL | `context.Database.Log` | `ToQueryString()` / `LogTo` |
| Timeout | `context.Database.CommandTimeout` | `UseSqlServer(..., o => o.CommandTimeout(30))` |
| `Include` | `System.Data.Entity` (string ou lambda) | `Microsoft.EntityFrameworkCore` |
| Avaliação no cliente | Silenciosa em vários casos | Lança exceção (3.0+) |
| Split query | Não existe | `AsSplitQuery()` |
| Update/Delete em massa | Não existe nativamente | `ExecuteUpdate`/`ExecuteDelete` (7+) |

---

## 1. Ver o SQL gerado

```csharp
using (var context = new MeuDbContext())
{
    // Registra TODO comando enviado ao banco, com parametros e duracao
    context.Database.Log = sql => Debug.Write(sql);

    var pedidos = context.Pedidos
                         .Where(p => p.ClienteId == clienteId)
                         .ToList();
}
```

Para ver apenas a tradução de uma consulta, sem executá-la:

```csharp
var query = context.Pedidos.Where(p => p.Valor > 1000);
var sql = query.ToString();     // em EF6, ToString() do IQueryable devolve o SQL
```

---

## 2. `N+1` por lazy loading

Em EF6, toda propriedade de navegação `virtual` é carregada sob demanda **por padrão**. O
contador de queries dispara sem nenhum sinal no código.

```csharp
// ❌ 1 + N queries
var pedidos = context.Pedidos.Take(100).ToList();
foreach (var p in pedidos)
    Console.WriteLine(p.Cliente.Nome);   // uma query por iteracao

// ✅ Eager loading
var pedidos = context.Pedidos
                     .Include(p => p.Cliente)
                     .Take(100)
                     .ToList();

// ✅✅ Projecao: so o necessario, sem materializar entidades
var pedidos = context.Pedidos
    .Select(p => new PedidoResumo
    {
        PedidoId    = p.PedidoId,
        Data        = p.Data,
        NomeCliente = p.Cliente.Nome
    })
    .Take(100)
    .ToList();
```

`Include` com lambda exige `using System.Data.Entity;`. Sem esse `using`, só a sobrecarga
com string fica disponível — e erro de digitação na string só aparece em tempo de execução.

### Desligar lazy loading

```csharp
public class MeuDbContext : DbContext
{
    public MeuDbContext() : base("name=MinhaConexao")
    {
        Configuration.LazyLoadingEnabled = false;
        Configuration.ProxyCreationEnabled = false;
    }
}
```

Em base legada, desligar de uma vez costuma quebrar telas que dependiam do carregamento
automático. O caminho seguro é desligar por consulta enquanto se corrige o código:

```csharp
context.Configuration.LazyLoadingEnabled = false;
```

> **Serialização é o pior caso.** Serializar uma entidade com lazy loading ligado percorre
> o grafo inteiro, disparando uma query por navegação. Uma única chamada de API pode gerar
> centenas de queries — e, em ciclos de referência, exceção de auto-referência. Nunca
> serialize entidades diretamente: use DTOs.

---

## 3. Rastreamento em consultas de leitura

```csharp
// ✅ Sem snapshot de mudancas
var pedidos = context.Pedidos
                     .AsNoTracking()
                     .Where(p => p.Data >= dataInicial)
                     .ToList();
```

Em EF6 o custo do rastreamento é mais sensível que no EF Core: o `DetectChanges` percorre
todas as entidades rastreadas a cada operação.

---

## 4. Inserção em massa — o comportamento quadrático

```csharp
// ❌ Fica exponencialmente mais lento a cada Add
foreach (var item in dezMilItens)
    context.Itens.Add(item);

context.SaveChanges();
```

A cada `Add`, o EF6 executa `DetectChanges` sobre **todas** as entidades já rastreadas. Com
dez mil itens, o custo cresce de forma quadrática — o famoso "começa rápido e vai
engasgando".

```csharp
// ✅ Desligar a deteccao automatica durante a carga
context.Configuration.AutoDetectChangesEnabled = false;
try
{
    foreach (var item in dezMilItens)
        context.Itens.Add(item);

    context.SaveChanges();
}
finally
{
    context.Configuration.AutoDetectChangesEnabled = true;
}
```

Ainda assim, `SaveChanges` emite **um `INSERT` por linha**. Para volume real, use
`SqlBulkCopy`:

```csharp
using (var bulk = new SqlBulkCopy(connectionString))
{
    bulk.DestinationTableName = "dbo.Item";
    bulk.BatchSize = 5000;
    bulk.BulkCopyTimeout = 120;

    bulk.ColumnMappings.Add("Produto", "Produto");
    bulk.ColumnMappings.Add("Quantidade", "Quantidade");

    bulk.WriteToServer(tabelaDeDados);
}
```

Ver [`../dapper/dapper-receitas-essenciais.md`](../dapper/dapper-receitas-essenciais.md).

---

## 5. Timeout

```csharp
context.Database.CommandTimeout = 60;   // segundos; null usa o padrao do provider
```

O padrão efetivo é o do ADO.NET: 30 segundos. Ver
[`../ado-net/timeout-de-comando-vs-conexao.md`](../ado-net/timeout-de-comando-vs-conexao.md).

---

## 6. Tempo de vida do `DbContext`

```csharp
// ✅ Um contexto por unidade de trabalho
using (var context = new MeuDbContext())
{
    // ...
    context.SaveChanges();
}
```

Em ASP.NET MVC 5 / WebForms, um contexto por requisição é o padrão adequado — registrado
no contêiner de DI com escopo de requisição, ou criado e descartado no controller.

**Nunca** um `DbContext` estático ou de vida longa: além de não ser thread-safe, ele
acumula entidades rastreadas indefinidamente, e o consumo de memória cresce até o processo
reciclar.

---

## 7. Erros comuns e o que significam

| Erro | Causa | Correção |
|---|---|---|
| `The ObjectContext instance has been disposed and can no longer be used for operations that require a connection` | Lazy loading acionado **depois** de o contexto ser descartado — quase sempre na view ou na serialização | Carregue com `Include`, ou projete para DTO dentro do `using` |
| `The model backing the context has changed since the database was created` | Esquema divergente do modelo | Reconciliar migrations; em legado, avaliar `Database.SetInitializer(null)` conscientemente |
| `Violation of PRIMARY KEY constraint` ao inserir | Entidade com chave já existente marcada como `Added` | Verificar o estado da entidade; usar `Attach` + estado `Modified` para atualização |
| `An entity object cannot be referenced by multiple instances of IEntityChangeTracker` | A mesma entidade em dois contextos | Um contexto por unidade de trabalho |
| `Store update, insert, or delete statement affected an unexpected number of rows (0)` | Concorrência otimista: a linha mudou ou sumiu entre a leitura e a gravação | Tratar `DbUpdateConcurrencyException` e decidir a política de resolução |
| `Timeout expired` | Ver [`../ado-net/timeout-de-comando-vs-conexao.md`](../ado-net/timeout-de-comando-vs-conexao.md) | |

---

## 8. Resiliência a erros transitórios

```csharp
public class MinhaConfiguracao : DbConfiguration
{
    public MinhaConfiguracao()
    {
        // Estrategia de repeticao para erros transitorios
        SetExecutionStrategy("System.Data.SqlClient",
                             () => new SqlAzureExecutionStrategy());
    }
}
```

Apesar do nome, `SqlAzureExecutionStrategy` trata erros transitórios que também ocorrem em
SQL Server local. Assim como no EF Core, com a estratégia ativa, transações iniciadas
manualmente precisam ser executadas dentro dela.

---

## 9. Migrations em produção

```powershell
# ✅ Gerar script SQL para revisao, em vez de aplicar direto
Update-Database -Script -SourceMigration:<Anterior> -TargetMigration:<Alvo>
```

O mesmo princípio do EF Core: gere, revise, teste em homologação, aplique na janela, com
plano de rollback escrito antes.

Evite `Database.SetInitializer` com estratégias que recriam o banco
(`DropCreateDatabaseIfModelChanges`) em qualquer ambiente que não seja descartável.

---

## Modernizar sem reescrever

EF6 não precisa ser trocado por EF Core de uma vez. Opções de baixo risco:

1. **Corrigir o `N+1`** — ganho imediato, sem trocar nada de infraestrutura.
2. **Introduzir Dapper para as consultas críticas**, mantendo EF6 para escrita. Convivem
   sem conflito na mesma conexão.
3. **EF 6.3+ roda em .NET Core 3.0 e superior** — o que permite migrar a plataforma sem
   reescrever a camada de dados no mesmo passo.

Ver [`../../sistemas-legados/modernizacao-incremental-strangler.md`](../../sistemas-legados/modernizacao-incremental-strangler.md).

## Referências

- [Entity Framework 6 — documentação](https://learn.microsoft.com/pt-br/ef/ef6/)
- [Considerações de desempenho no EF6](https://learn.microsoft.com/pt-br/ef/ef6/fundamentals/performance/perf-whitepaper)
- [Resiliência de conexão no EF6](https://learn.microsoft.com/pt-br/ef/ef6/fundamentals/connection-resiliency/retry-logic)

---

**Criado por Fábio Cerqueira**
