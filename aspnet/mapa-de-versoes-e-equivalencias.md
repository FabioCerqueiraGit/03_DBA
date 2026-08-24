# ASP.NET ao longo das versões — mapa e tabela de equivalências

> "Como eu faço isso aqui, se no sistema antigo era assim?" — a tradução entre WebForms, MVC 5,
> Web API 2 e ASP.NET Core, para quem mantém os dois mundos ao mesmo tempo.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.x (WebForms, MVC 5, Web API 2) e ASP.NET Core em .NET 8, 9 e 10. |
| **Impacto** | Documento de referência. Nenhum. |
| **Verificado em** | Política de suporte do .NET, agosto de 2026. |

---

## Problema

Quem trabalha com .NET há mais de uma década carrega três ou quatro modelos de programação web na
cabeça ao mesmo tempo. O risco prático não é esquecer sintaxe — é **aplicar uma solução moderna a
um sistema legado como se fosse compatível**.

Exemplos que aparecem em produção com regularidade:

- Usar `IHttpClientFactory` em uma aplicação .NET Framework, onde ela não existe da mesma forma;
- Esperar que `HttpContext.Current` funcione em ASP.NET Core — ele simplesmente não existe;
- Copiar `async`/`await` de um exemplo de Core para dentro de um WebForms sem
  `Async="true"` na página;
- Assumir que `Server.MapPath` ou `ConfigurationManager.AppSettings` continuam disponíveis.

Este documento existe para dar a **equivalência correta**, não a substituição aproximada.

---

## A linha do tempo, em ordem prática

| Plataforma | Roda sobre | Modelo | Situação hoje |
|---|---|---|---|
| ASP.NET WebForms | .NET Framework | Postback, ViewState, controles de servidor | Suportado enquanto o .NET Framework for suportado. **Sem caminho de migração direto para Core** |
| ASP.NET MVC 5 | .NET Framework | Controller + View, roteamento | Suportado. Migração para Core é viável e bem trilhada |
| ASP.NET Web API 2 | .NET Framework | Controller HTTP, sem View | Suportado. Migração para Core é a mais simples das três |
| ASP.NET Core 1.x–2.x | .NET Framework **ou** .NET Core | Unificado (MVC + Web API) | Fora de suporte |
| ASP.NET Core 3.0+ | Apenas .NET Core / .NET 5+ | Unificado, endpoint routing | Atual |

> **O corte que muita gente não conhece:** ASP.NET Core 2.x ainda podia rodar sobre o .NET
> Framework. A partir do **3.0**, isso acabou. Portanto, "vamos migrar para o ASP.NET Core mantendo
> o .NET Framework" não é mais uma opção em nenhuma versão suportada.

### Versões do .NET em suporte

| Versão | Tipo | Lançamento | Fim do suporte |
|---|---|---|---|
| .NET 10 | LTS | 11/11/2025 | 14/11/2028 |
| .NET 9 | STS | 12/11/2024 | 10/11/2026 |
| .NET 8 | LTS | 14/11/2023 | 10/11/2026 |

LTS tem três anos de suporte; STS, dois. Lançamentos ocorrem em novembro; versões pares são LTS.

**Consequência prática em agosto de 2026:** .NET 8 e .NET 9 estão na fase de manutenção (apenas
correções de segurança) e saem de suporte em novembro. Sistema que ainda está no 8 tem uma
decisão de planejamento a tomar agora, não em outubro.

O **.NET Framework 4.8 / 4.8.1** segue outro regime: é componente do Windows e acompanha o ciclo
do sistema operacional. Não há pressão de fim de suporte no curto prazo — mas também não haverá
novas funcionalidades.

---

## Tabela de equivalências

### Configuração

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Ler configuração | `ConfigurationManager.AppSettings["Chave"]` | `IConfiguration["Chave"]` injetado |
| Connection string | `ConfigurationManager.ConnectionStrings["Nome"].ConnectionString` | `configuration.GetConnectionString("Nome")` |
| Configuração tipada | Seção customizada em `web.config` | `services.Configure<T>(configuration.GetSection("X"))` + `IOptions<T>` |
| Por ambiente | `web.Release.config` (XDT transform) | `appsettings.{Environment}.json` |
| Arquivo | `web.config` (XML) | `appsettings.json` + variáveis de ambiente |

### Ciclo de vida e contexto

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Contexto da requisição | `HttpContext.Current` (estático, global) | `HttpContext` injetado, ou `IHttpContextAccessor` |
| Caminho físico | `Server.MapPath("~/arquivos")` | `IWebHostEnvironment.ContentRootPath` / `WebRootPath` |
| Inicialização | `Global.asax` → `Application_Start` | `Program.cs` |
| Fim da requisição | `Application_EndRequest` | Middleware, ou `HttpContext.Response.OnCompleted` |
| Erro global | `Application_Error` | `UseExceptionHandler` / middleware próprio |
| Usuário autenticado | `HttpContext.Current.User` | `HttpContext.User` |

> **`HttpContext.Current` é a maior armadilha da migração.** No ASP.NET Core ele não existe. Muito
> código legado depende dele em camadas profundas — repositórios, helpers, serviços — e essa
> dependência só aparece em tempo de execução. `IHttpContextAccessor` resolve tecnicamente, mas
> propagá-lo pelo sistema inteiro perpetua o acoplamento. O caminho melhor é passar o que é
> realmente necessário (o usuário, o tenant, o correlation ID) como parâmetro.

### Injeção de dependência

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Container | Nenhum embutido — Unity, Autofac, Ninject, StructureMap | Embutido: `IServiceCollection` |
| Registro | Varia por container | `services.AddScoped<IServico, Servico>()` |
| Escopo por requisição | Configuração específica de cada container | `AddScoped` é o escopo de requisição |
| Resolução em WebForms | `Page` não tem construtor com parâmetros — exige service locator | Não se aplica |

### Roteamento e ações

| Tarefa | MVC 5 / Web API 2 | ASP.NET Core |
|---|---|---|
| Rota por convenção | `RouteConfig.RegisterRoutes` | `app.MapControllerRoute(...)` |
| Rota por atributo | `[Route("api/pedidos/{id}")]` | Igual |
| Retorno de ação | `IHttpActionResult` (Web API) / `ActionResult` (MVC) | `IActionResult` / `ActionResult<T>` |
| Status HTTP | `Ok()`, `NotFound()`, `BadRequest()` | Iguais |
| Filtros | `ActionFilterAttribute`, `IExceptionFilter` | Iguais em nome, namespace diferente |
| Bind do corpo | Inferido em Web API | `[FromBody]` — **precisa ser explícito** em muitos casos |

> **Diferença que quebra silenciosamente:** no Web API 2, o binding do corpo era inferido para
> tipos complexos. No ASP.NET Core, controllers com `[ApiController]` inferem também — mas sem esse
> atributo, um parâmetro complexo pode ser buscado na query string e chegar `null`. Se um endpoint
> migrado passou a receber `null`, comece por aqui.

### HTTP de saída

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Cliente HTTP | `HttpClient` **estático e reutilizado** | `IHttpClientFactory` |
| DNS obsoleto | `ServicePointManager.FindServicePoint(...).ConnectionLeaseTimeout` | `SocketsHttpHandler.PooledConnectionLifetime` |
| Limite de conexões | `ServicePointManager.DefaultConnectionLimit` | `SocketsHttpHandler.MaxConnectionsPerServer` |
| Protocolo TLS | `ServicePointManager.SecurityProtocol` (ver [`seguranca/certificados/`](../seguranca/certificados/tls-e-certificados-em-dotnet.md)) | Padrão do sistema operacional |

Detalhes em [`dotnet/httpclient/`](../dotnet/httpclient/).

### Logging

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Abstração | log4net, NLog, Serilog direto | `ILogger<T>` injetado |
| Configuração | `web.config` ou arquivo próprio | `appsettings.json`, seção `Logging` |
| Escopo | Recurso de cada biblioteca | `logger.BeginScope(...)` |

Ver [`dotnet/logging/`](../dotnet/logging/).

### Sessão, cache e estado

| Tarefa | .NET Framework | ASP.NET Core |
|---|---|---|
| Sessão | `Session["chave"]`, ligada por padrão | `AddSession()` + `UseSession()`, **desligada por padrão** |
| Cache em memória | `HttpRuntime.Cache` / `MemoryCache.Default` | `IMemoryCache` |
| Cache distribuído | Provider de estado de sessão | `IDistributedCache` |
| ViewState | Exclusivo de WebForms | Não existe |

### Assíncrono

| Contexto | Comportamento |
|---|---|
| WebForms | Exige `<%@ Page Async="true" %>` e `RegisterAsyncTask`. Sem isso, `async void` no code-behind produz comportamento imprevisível |
| MVC 5 / Web API 2 | `async Task<ActionResult>` funciona, mas há `SynchronizationContext` — `.Result` ou `.Wait()` causa **deadlock** |
| ASP.NET Core | Não há `SynchronizationContext`. `ConfigureAwait(false)` deixa de ser necessário em código de aplicação (continua importando em bibliotecas) |

O deadlock por `sync-over-async` é o problema mais caro dessa lista. Detalhamento em
[`dotnet/async-await/`](../dotnet/async-await/).

---

## Legado → Intermediário → Moderno

As instruções deste repositório pedem, quando houver diferença relevante, que a solução seja
apresentada em três estágios. O exemplo abaixo mostra o padrão aplicado a **acesso à
configuração**:

### Legado — WebForms / MVC 5, acoplado

```csharp
// Espalhado pelo codigo, sem teste possivel
public class RepositorioPedido
{
    public Pedido Obter(int id)
    {
        var conexao = ConfigurationManager
            .ConnectionStrings["Principal"].ConnectionString;
        // ...
    }
}
```

### Intermediário — ainda .NET Framework, mas invertido

```csharp
// Continua lendo do web.config, mas a dependencia agora e explicita
// e substituivel em teste. Este passo NAO exige migrar de plataforma.
public interface IConfiguracaoBanco
{
    string ConexaoPrincipal { get; }
}

public sealed class ConfiguracaoBancoDoWebConfig : IConfiguracaoBanco
{
    public string ConexaoPrincipal =>
        ConfigurationManager.ConnectionStrings["Principal"]?.ConnectionString
        ?? throw new ConfigurationErrorsException(
               "Connection string 'Principal' nao configurada.");
}

public class RepositorioPedido
{
    private readonly IConfiguracaoBanco _configuracao;

    public RepositorioPedido(IConfiguracaoBanco configuracao) =>
        _configuracao = configuracao;
}
```

### Moderno — ASP.NET Core

```csharp
// Program.cs
builder.Services.Configure<OpcoesBanco>(
    builder.Configuration.GetSection("Banco"));

// Consumo
public class RepositorioPedido
{
    private readonly OpcoesBanco _opcoes;

    public RepositorioPedido(IOptions<OpcoesBanco> opcoes) =>
        _opcoes = opcoes.Value;
}
```

O ponto do estágio intermediário: **ele já entrega valor sem migrar de plataforma**, e reduz o
tamanho da migração quando ela vier. Sistema legado se moderniza assim — por interfaces
introduzidas onde dói, não por reescrita.

---

## O que NÃO tem equivalente

Honestidade importa mais que otimismo aqui:

| Recurso do .NET Framework | Situação no ASP.NET Core |
|---|---|
| **WebForms** | Não existe e não existirá. Migração é reescrita da camada de apresentação — Blazor ou MVC são os destinos usuais |
| **WCF (lado servidor)** | Não há equivalente da Microsoft. Existe o CoreWCF, projeto da .NET Foundation. Consumo de serviços SOAP é possível via cliente gerado |
| **`System.Web`** | Removido. Daí a existência dos System.Web adapters (ver abaixo) |
| **Web Pages / Razor Pages clássico (`.cshtml` sem MVC)** | Razor Pages é outro modelo, com nome parecido |
| **AppDomain múltiplo** | Não existe. Isolamento é por processo ou por `AssemblyLoadContext` |
| **`ConfigurationManager` com seções customizadas** | O modelo de configuração é outro |

Essa tabela costuma ser a parte mais útil de uma conversa sobre migração, porque delimita o que
**não** é negociável no escopo.

---

## Quando NÃO migrar

Migrar para ASP.NET Core é quase sempre a direção certa no longo prazo, e quase nunca a atividade
mais urgente. Não priorize a migração quando:

- **O sistema é estável e está em fim de vida** — substituição por outro produto já contratada.
- **O gargalo é outro.** Se o problema é lentidão de banco, migrar a plataforma web não resolve.
  Comece por [`sql-server/troubleshooting/`](../sql-server/troubleshooting/).
- **É WebForms com centenas de telas** e não há orçamento para reescrever a apresentação. Nesse
  caso, o trabalho útil é extrair a lógica de negócio para bibliotecas testáveis e independentes
  de `System.Web` — o que reduz a migração futura e melhora o sistema hoje.
- **Não há nenhum teste automatizado.** Migrar sem rede de segurança é apostar. Escrever testes de
  caracterização nos fluxos críticos vem primeiro — ver
  [`sistemas-legados/`](../sistemas-legados/).

---

## O caminho incremental

A Microsoft mantém um caminho oficial de migração **incremental**, que evita a reescrita de uma vez
só. A ideia é colocar uma aplicação ASP.NET Core na frente, com proxy reverso, e mover rotas do
sistema antigo para o novo uma por vez — exatamente o padrão Strangler Fig descrito em
[`sistemas-legados/`](../sistemas-legados/).

Peças envolvidas:

- **YARP** — proxy reverso que encaminha ao aplicativo original tudo o que ainda não migrou.
- **`Microsoft.AspNetCore.SystemWebAdapters`** — permite que bibliotecas que usam `HttpContext`
  compilem para .NET Standard 2.0 ou .NET 8+, sem depender de `System.Web`.
- **`Microsoft.AspNetCore.SystemWebAdapters.FrameworkServices`** — instalado no aplicativo
  .NET Framework; a instalação registra um módulo no `web.config`.

No aplicativo ASP.NET Core:

```csharp
builder.Services.AddSystemWebAdapters();

// ...

// O middleware entra depois do roteamento e antes dos endpoints.
app.UseSystemWebAdapters();
```

Os adapters oferecem também compartilhamento **remoto** de sessão e de autenticação, o que permite
que as duas aplicações convivam com o mesmo usuário logado durante a transição. Essa é a parte que
costuma decidir a viabilidade do projeto — vale ler a documentação específica de sessão e
autenticação antes de estimar prazo.

Ordem recomendada: subir o proxy → pagar débito técnico no aplicativo antigo → resolver os
aspectos transversais (sessão, autenticação, log, cache) → subir as bibliotecas de apoio, das
folhas para a raiz → migrar rotas.

---

## Referências

- [.NET — Política de suporte](https://dotnet.microsoft.com/platform/support/policy/dotnet-core)
- [Microsoft Learn — Get started with incremental ASP.NET to ASP.NET Core migration](https://learn.microsoft.com/aspnet/core/migration/fx-to-core/start)
- [`dotnet/systemweb-adapters`](https://github.com/dotnet/systemweb-adapters)
- [Microsoft Learn — Configuration in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/)
- [Microsoft Learn — Dependency injection in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/dependency-injection)
- [Microsoft Learn — Session and state management in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/app-state)

---

**Criado por Fábio Cerqueira**
