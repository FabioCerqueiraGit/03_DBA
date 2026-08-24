# Tempos de vida na injeção de dependência — e a dependência cativa

> "A second operation was started on this context instance", `DbContext` já descartado, cache que
> devolve o dado de outro usuário. Quase sempre um `Scoped` preso dentro de um `Singleton`.

| | |
|---|---|
| **Compatibilidade** | `Microsoft.Extensions.DependencyInjection` — ASP.NET Core 2.0+, também usável em console e serviços. Seção final trata de .NET Framework. |
| **Impacto** | Erro de tempo de vida produz falha intermitente sob concorrência: difícil de reproduzir, fácil de prevenir. |

---

## Os três tempos de vida

| Tempo de vida | Uma instância por | Use para |
|---|---|---|
| `Transient` | **Cada resolução** | Serviços leves e sem estado |
| `Scoped` | **Cada requisição** (ou escopo criado manualmente) | `DbContext`, unidade de trabalho, contexto do usuário |
| `Singleton` | **Toda a aplicação** | Cache, configuração, objetos caros e imutáveis |

```csharp
builder.Services.AddTransient<ICalculadoraDeFrete, CalculadoraDeFrete>();
builder.Services.AddScoped<IRepositorioPedido, RepositorioPedido>();
builder.Services.AddSingleton<ICacheDeParametros, CacheDeParametros>();

// AddDbContext registra como Scoped por padrao. Isso e proposital.
builder.Services.AddDbContext<MeuDbContext>(opcoes =>
    opcoes.UseSqlServer(configuracao.GetConnectionString("Principal")));
```

---

## A dependência cativa

> **Um serviço nunca deve depender de outro com tempo de vida mais curto que o seu.**

Quando um `Singleton` recebe um `Scoped` pelo construtor, aquela instância `Scoped` é criada uma
vez e **fica presa** dentro do singleton pelo resto da vida do processo. Ela deixa de ser "por
requisição" e passa a ser compartilhada por todas.

```csharp
// ERRADO
public sealed class CacheDeParametros : ICacheDeParametros   // registrado como Singleton
{
    private readonly MeuDbContext _contexto;                 // Scoped — fica cativo

    public CacheDeParametros(MeuDbContext contexto) => _contexto = contexto;
}
```

Consequências, em ordem de aparição:

1. **`InvalidOperationException: A second operation was started on this context instance...`** — o
   `DbContext` não é seguro para uso concorrente, e agora duas requisições simultâneas o usam.
2. **`ObjectDisposedException`** — o escopo original terminou e descartou o contexto; o singleton
   continua segurando a referência.
3. **Vazamento de dado entre usuários** — o *change tracker* acumula entidades de todas as
   requisições. Além do consumo crescente de memória, um usuário pode enxergar dado de outro.
4. **Conexão retida** — contribui para o esgotamento do connection pool. Ver
   [`acesso-a-dados/ado-net/`](../../acesso-a-dados/ado-net/).

O sintoma 3 é o mais grave e o menos visível: não gera exceção.

---

## A correção: `IServiceScopeFactory`

Quando um singleton **precisa** de algo com escopo, ele cria o escopo por operação:

```csharp
public sealed class CacheDeParametros : ICacheDeParametros
{
    private readonly IServiceScopeFactory _fabricaDeEscopo;

    public CacheDeParametros(IServiceScopeFactory fabricaDeEscopo) =>
        _fabricaDeEscopo = fabricaDeEscopo;

    public async Task<Parametro?> ObterAsync(
        string chave, CancellationToken cancellationToken)
    {
        // Escopo proprio, com vida curta e bem delimitada.
        using var escopo = _fabricaDeEscopo.CreateScope();

        var contexto = escopo.ServiceProvider.GetRequiredService<MeuDbContext>();

        return await contexto.Parametros
            .AsNoTracking()
            .FirstOrDefaultAsync(p => p.Chave == chave, cancellationToken);
    }
}
```

O `using` é obrigatório: sem ele, o escopo nunca é descartado e o `DbContext` — junto com sua
conexão — vaza a cada chamada.

> Antes de aplicar esse padrão, pergunte se o serviço precisa mesmo ser singleton. Muitas vezes
> `Scoped` resolve, e aí não há escopo a criar. `IServiceScopeFactory` é a resposta certa para
> singletons genuínos: serviços em segundo plano, caches e coisas que vivem fora do ciclo da
> requisição.

---

## O container detecta isso — se você deixar

```csharp
// Program.cs
var builder = WebApplication.CreateBuilder(args);

builder.Host.UseDefaultServiceProvider(opcoes =>
{
    // Falha ao resolver um Scoped a partir do provedor raiz.
    opcoes.ValidateScopes  = true;

    // Valida TODO o grafo de dependencias na inicializacao,
    // em vez de esperar a primeira requisicao que use aquele servico.
    opcoes.ValidateOnBuild = true;
});
```

Ambas são ativadas por padrão no ambiente `Development` e **desativadas em produção**, por custo de
inicialização. Ligar `ValidateOnBuild` também em produção troca uma falha intermitente sob carga
por uma falha determinística na subida — troca que quase sempre compensa.

---

## Casos que sempre aparecem

### Middleware

O construtor de um middleware roda **uma única vez**, na inicialização. Ele é, na prática, um
singleton.

```csharp
// ERRADO: promove o DbContext a singleton
public MeuMiddleware(RequestDelegate proximo, MeuDbContext contexto) { }

// CERTO: o parametro do InvokeAsync e resolvido no escopo da requisicao
public async Task InvokeAsync(HttpContext contexto, MeuDbContext banco) { }
```

Ver [`aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md`](../../aspnet/aspnet-core/ordem-do-pipeline-de-middleware.md).

### `IHttpContextAccessor` em singleton

`IHttpContextAccessor` é singleton e usa `AsyncLocal` internamente — ele funciona. Mas
`HttpContext` é `null` fora de uma requisição (serviço em segundo plano, inicialização, job).
Tratar esse `null` é obrigatório.

### `IOptions<T>` versus `IOptionsSnapshot<T>`

| Interface | Tempo de vida | Recarrega? |
|---|---|---|
| `IOptions<T>` | Singleton | Não. Valor lido na inicialização |
| `IOptionsSnapshot<T>` | **Scoped** | Sim, uma vez por requisição |
| `IOptionsMonitor<T>` | Singleton | Sim, com notificação de mudança |

Injetar `IOptionsSnapshot<T>` em um singleton é dependência cativa. Em singleton que precisa
acompanhar mudança de configuração, o correto é `IOptionsMonitor<T>`.

### `IDisposable` e quem descarta

| Registro | Quem descarta |
|---|---|
| `Transient` e `Scoped` | O escopo, ao terminar |
| `Singleton` | O provedor raiz, ao encerrar a aplicação |
| Instância passada pronta (`AddSingleton(new Servico())`) | **Ninguém.** É responsabilidade de quem criou |

> Um `Transient` que implementa `IDisposable` resolvido a partir do **provedor raiz** é acumulado
> até o fim da aplicação — vazamento de memória progressivo. Dentro de uma requisição isso não
> ocorre, porque o escopo termina. Em serviço em segundo plano, ocorre.

---

## Introduzir DI em sistema legado (.NET Framework)

Não é preciso adotar um container para começar a se beneficiar. O primeiro passo — e o que mais
rende — é **tornar a dependência explícita**:

```csharp
// Antes: dependencia escondida, impossivel de testar
public class ServicoPedido
{
    public void Processar(int id)
    {
        var repositorio = new RepositorioPedido();          // acoplado
        var email = new ServicoEmail(
            ConfigurationManager.AppSettings["SmtpHost"]);  // acoplado
    }
}

// Depois: mesmo comportamento, dependencia explicita.
// O construtor sem parametros mantem o codigo existente compilando.
public class ServicoPedido
{
    private readonly IRepositorioPedido _repositorio;
    private readonly IServicoEmail _email;

    public ServicoPedido(IRepositorioPedido repositorio, IServicoEmail email)
    {
        _repositorio = repositorio;
        _email       = email;
    }

    // Ponte temporaria enquanto o resto do sistema nao foi convertido.
    // Marque com data de remocao.
    public ServicoPedido()
        : this(new RepositorioPedido(),
               new ServicoEmail(ConfigurationManager.AppSettings["SmtpHost"]))
    {
    }
}
```

Esse padrão — conhecido como *poor man's DI* — já permite escrever teste com dublê, sem adicionar
nenhum pacote e sem tocar em quem chama. Quando fizer sentido, o container (Unity, Autofac,
SimpleInjector) entra e o construtor de ponte é removido.

**WebForms** é o caso mais difícil: `Page` não tem construtor com parâmetros e o ciclo de vida é do
runtime. A abordagem viável é resolver os serviços no `Page_Load` a partir de um localizador —
aceitável como estágio intermediário, desde que a lógica de negócio esteja fora do code-behind.

Ver [`sistemas-legados/`](../../sistemas-legados/) e
[`aspnet/mapa-de-versoes-e-equivalencias.md`](../../aspnet/mapa-de-versoes-e-equivalencias.md).

---

## Checklist

- [ ] Nenhum serviço depende de outro com tempo de vida mais curto.
- [ ] `DbContext` registrado como `Scoped` e nunca injetado em singleton.
- [ ] Singletons que precisam de `Scoped` usam `IServiceScopeFactory` com `using`.
- [ ] `ValidateScopes` e `ValidateOnBuild` ligados — inclusive em produção.
- [ ] Nenhum serviço `Scoped` no construtor de middleware.
- [ ] `IOptionsMonitor<T>` em singleton; `IOptionsSnapshot<T>` só em `Scoped`.
- [ ] `HttpContext` verificado contra `null` quando obtido por `IHttpContextAccessor`.
- [ ] Nenhum `Transient` descartável resolvido a partir do provedor raiz.

---

## Referências

- [Microsoft Learn — Dependency injection in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/dependency-injection)
- [Microsoft Learn — Dependency injection guidelines](https://learn.microsoft.com/dotnet/core/extensions/dependency-injection-guidelines)
- [Microsoft Learn — `DbContext` lifetime, configuration, and initialization](https://learn.microsoft.com/ef/core/dbcontext-configuration/)
- [Microsoft Learn — Options pattern in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/options)

---

**Criado por Fábio Cerqueira**
