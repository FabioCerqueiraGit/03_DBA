# Ordem do pipeline de middleware no ASP.NET Core

> Autorização que não autoriza, CORS que não libera, log sem usuário, arquivo estático protegido
> que qualquer um baixa — quase sempre o mesmo defeito: uma linha no lugar errado.

| | |
|---|---|
| **Compatibilidade** | ASP.NET Core 3.0+; exemplos escritos para o modelo de `Program.cs` de .NET 6+. |
| **Impacto** | **Alto.** Erro de ordem aqui produz falha de segurança silenciosa — sem exceção, sem log. |

---

## Problema

O pipeline do ASP.NET Core é uma sequência. Cada middleware roda na ordem em que foi registrado na
ida, e na ordem inversa na volta. Isso significa que **a ordem é a lógica**, e um registro fora de
lugar não gera erro de compilação nem exceção em tempo de execução. A aplicação sobe, responde
200 e faz a coisa errada.

Os sintomas mais comuns e sua causa:

| Sintoma | Causa quase certa |
|---|---|
| `[Authorize]` parece não fazer efeito | `UseAuthorization()` antes de `UseAuthentication()`, ou ambos antes de `UseRouting()` |
| `User.Identity.IsAuthenticated` sempre `false` no middleware | O middleware roda **antes** de `UseAuthentication()` |
| CORS não libera, mesmo configurado | `UseCors()` depois da autorização, ou depois do mapeamento de endpoint |
| Log sem o nome do usuário | Middleware de log registrado antes da autenticação |
| Arquivo em `wwwroot` acessível sem login | Comportamento **esperado**: `UseStaticFiles()` vem antes da autenticação e curto-circuita |
| Exceção vaza stack trace em produção | Tratamento de exceção registrado tarde demais |

---

## A ordem de referência

```csharp
var app = builder.Build();

// 1. Tratamento de excecao PRIMEIRO.
//    Ele envolve tudo o que vem depois; o que estiver acima dele nao e protegido.
if (app.Environment.IsDevelopment())
{
    app.UseDeveloperExceptionPage();
}
else
{
    app.UseExceptionHandler("/erro");
    app.UseHsts();
}

// 2. Redirecionamento para HTTPS
app.UseHttpsRedirection();

// 3. Arquivos estaticos.
//    Cedo de proposito: curto-circuita e evita o custo do resto do pipeline.
//    ATENCAO: por isso mesmo, arquivo em wwwroot NAO passa por autenticacao.
app.UseStaticFiles();

// 4. Politica de cookie, quando aplicavel
// app.UseCookiePolicy();

// 5. Roteamento: decide QUAL endpoint atendera a requisicao.
//    Precisa vir antes de tudo que depende da rota escolhida.
app.UseRouting();

// 6. Localizacao, se usar provedor baseado em dados de rota
// app.UseRequestLocalization();

// 7. CORS — depois do roteamento, antes de autenticacao/autorizacao
//    e antes de UseResponseCaching.
app.UseCors("PoliticaPadrao");

// 8. Autenticacao: QUEM e o usuario.
//    Nao rejeita ninguem — apenas popula HttpContext.User.
app.UseAuthentication();

// 9. Autorizacao: esse usuario PODE acessar este endpoint.
//    Depende do passo 5 (qual endpoint) e do passo 8 (quem e).
app.UseAuthorization();

// 10. Antiforgery — depois de autenticacao e autorizacao
// app.UseAntiforgery();

// 11. Sessao, se usada
// app.UseSession();

// 12. Compressao e cache de resposta
// app.UseResponseCompression();
// app.UseResponseCaching();

// 13. Endpoints
app.MapControllers();

app.Run();
```

---

## As três relações que explicam quase tudo

### `UseRouting` → `UseAuthentication` → `UseAuthorization`

Essa ordem não é convenção — é dependência de dados:

1. **`UseRouting`** escolhe o endpoint. Só depois dele existe a informação de que aquele endpoint
   tem `[Authorize(Roles = "Financeiro")]`.
2. **`UseAuthentication`** lê o cookie ou o token e preenche `HttpContext.User`. Ele **não
   rejeita** requisição anônima — apenas identifica quem é, se for possível.
3. **`UseAuthorization`** cruza as duas informações: este usuário pode acessar este endpoint?

Inverter 2 e 3 faz a autorização avaliar um `User` anônimo. Colocar ambos antes de `UseRouting`
faz a autorização não saber qual endpoint está sendo protegido.

> **O que torna isso perigoso:** em um cenário, tudo passa a ser negado — e alguém percebe rapido.
> No outro, um endpoint deixa de ser protegido e **ninguém percebe nunca**. Por isso vale um teste
> de integração que chame um endpoint protegido sem credencial e afirme `401`/`403`. É barato e
> pega regressão de ordem.

### Arquivos estáticos curto-circuitam

`UseStaticFiles()` responde e **encerra** a requisição quando o arquivo existe. Como ele vem antes
da autenticação, tudo em `wwwroot` é público. Isso é intencional e correto para CSS e imagem — e
é uma exposição de dados se alguém colocou relatórios em PDF ali.

Para servir arquivo protegido, não mova `UseStaticFiles()` para depois da autorização — isso
custaria o pipeline inteiro em cada CSS. Sirva por endpoint:

```csharp
app.MapGet("/documentos/{id:guid}", async (Guid id, IServicoDocumento servico) =>
{
    var documento = await servico.ObterAsync(id);
    return documento is null
        ? Results.NotFound()
        : Results.File(documento.Conteudo, documento.TipoMime, documento.Nome);
})
.RequireAuthorization();
```

Os arquivos, nesse caso, ficam **fora** de `wwwroot`.

### O que vem antes não é protegido pelo que vem depois

O tratamento de exceção só captura o que está abaixo dele. Registrar `UseExceptionHandler` no meio
do pipeline deixa a metade de cima sem rede.

A mesma lógica vale para o middleware de correlation ID: ele precisa estar **bem no topo**, para
que o identificador exista quando o tratamento de exceção for registrar o erro. Ver
[`dotnet/logging/correlation-id-e-rastreabilidade.md`](../../dotnet/logging/correlation-id-e-rastreabilidade.md).

---

## Escrever um middleware próprio

```csharp
public sealed class MiddlewareDeTempoDeResposta
{
    private readonly RequestDelegate _proximo;
    private readonly ILogger<MiddlewareDeTempoDeResposta> _logger;

    public MiddlewareDeTempoDeResposta(
        RequestDelegate proximo, ILogger<MiddlewareDeTempoDeResposta> logger)
    {
        _proximo = proximo;
        _logger  = logger;
    }

    public async Task InvokeAsync(HttpContext contexto)
    {
        var inicio = Stopwatch.GetTimestamp();

        try
        {
            // Chamar _proximo e OBRIGATORIO, exceto quando o middleware
            // deliberadamente encerra a requisicao.
            await _proximo(contexto);
        }
        finally
        {
            var decorrido = Stopwatch.GetElapsedTime(inicio);   // .NET 7+

            if (decorrido.TotalMilliseconds > 1000)
            {
                _logger.LogWarning(
                    "Requisicao lenta. Metodo={Metodo} Caminho={Caminho} " +
                    "Status={Status} DuracaoMs={Duracao}",
                    contexto.Request.Method,
                    contexto.Request.Path,
                    contexto.Response.StatusCode,
                    decorrido.TotalMilliseconds);
            }
        }
    }
}

// Registro
app.UseMiddleware<MiddlewareDeTempoDeResposta>();
```

### Regras para middleware próprio

- **O construtor é chamado uma única vez**, na inicialização. Ele é efetivamente *singleton*.
  Nunca injete um serviço `Scoped` (como um `DbContext`) pelo construtor — isso o promove a
  singleton e produz erro de concorrência difícil de diagnosticar. Injete no `InvokeAsync`:

```csharp
public async Task InvokeAsync(HttpContext contexto, IServicoPorRequisicao servico)
{
    // 'servico' e resolvido no escopo da requisicao. Correto.
}
```

- **Não modifique cabeçalhos depois de a resposta começar.** `contexto.Response.HasStarted` diz se
  ainda dá. Ignorar isso gera `InvalidOperationException` intermitente sob carga.
- **`try/finally`, não `try/catch` genérico.** Engolir exceção no middleware esconde o erro do
  tratamento global.

---

## Equivalência com o .NET Framework

| ASP.NET Core | ASP.NET (System.Web) |
|---|---|
| Middleware | `IHttpModule` |
| `UseXxx()` no `Program.cs` | `<system.webServer><modules>` no `web.config` |
| Ordem de registro no código | Ordem dos eventos do `HttpApplication` |
| Endpoint terminal | `IHttpHandler` |
| `UseExceptionHandler` | `Application_Error` no `Global.asax` |
| `IActionFilter` | `ActionFilterAttribute` (MVC 5 / Web API 2) |

A diferença conceitual que mais confunde na migração: no `System.Web`, módulos se inscrevem em
**eventos nomeados** do ciclo de vida (`BeginRequest`, `AuthenticateRequest`,
`AuthorizeRequest`, `EndRequest`) e o runtime decide a ordem. No ASP.NET Core, não há eventos: há
uma fila, e **você** define a ordem.

Isso é mais previsível — e transfere a responsabilidade inteira para quem escreve o `Program.cs`.

---

## Quando NÃO usar middleware

| Necessidade | Melhor ferramenta |
|---|---|
| Lógica que vale só para alguns controllers | Filtro (`IActionFilter`, `IAsyncActionFilter`) |
| Validação de modelo | Model binding e validação, não middleware |
| Regra de negócio | Camada de aplicação. Middleware é infraestrutura de requisição |
| Algo que precisa do resultado da ação | Filtro de resultado — middleware não enxerga o `IActionResult` |
| Trabalho pesado em toda requisição | Reconsidere. Middleware roda **em tudo**, inclusive no *health check* |

Um middleware que faz consulta a banco em toda requisição é uma das causas mais comuns de
esgotamento de connection pool sob carga — ver
[`acesso-a-dados/ado-net/`](../../acesso-a-dados/ado-net/).

---

## Diagnosticar a ordem de um pipeline existente

O jeito mais direto de ver a ordem real é registrar um marcador entre cada etapa, temporariamente:

```csharp
// Diagnostico TEMPORARIO. Remover depois.
app.Use(async (contexto, proximo) =>
{
    Console.WriteLine($"[ANTES DA AUTENTICACAO] Autenticado={contexto.User?.Identity?.IsAuthenticated}");
    await proximo();
});

app.UseAuthentication();

app.Use(async (contexto, proximo) =>
{
    Console.WriteLine($"[DEPOIS DA AUTENTICACAO] Autenticado={contexto.User?.Identity?.IsAuthenticated} Usuario={contexto.User?.Identity?.Name}");
    await proximo();
});
```

Se o segundo marcador também mostrar `False` para uma requisição com credencial válida, o problema
não é de ordem — é de configuração do esquema de autenticação.

O log em nível `Debug` da categoria `Microsoft.AspNetCore` também mostra a seleção de endpoint e o
resultado da autorização — útil em ambiente de desenvolvimento, e caro demais para deixar ligado
em produção.

---

## Checklist

- [ ] Tratamento de exceção é o **primeiro** middleware.
- [ ] `UseRouting()` antes de `UseAuthentication()` e `UseAuthorization()`.
- [ ] `UseAuthentication()` imediatamente antes de `UseAuthorization()`.
- [ ] `UseCors()` depois de `UseRouting()` e antes de `UseResponseCaching()`.
- [ ] Nenhum arquivo sensível em `wwwroot`.
- [ ] Middleware de correlation ID no topo, antes do tratamento de exceção registrar qualquer erro.
- [ ] Nenhum serviço `Scoped` injetado no **construtor** de middleware.
- [ ] Teste de integração que chama um endpoint protegido sem credencial e espera `401`/`403`.
- [ ] Nenhum acesso a banco em middleware que roda em toda requisição.

---

## Referências

- [Microsoft Learn — ASP.NET Core Middleware](https://learn.microsoft.com/aspnet/core/fundamentals/middleware/)
- [Microsoft Learn — Write custom ASP.NET Core middleware](https://learn.microsoft.com/aspnet/core/fundamentals/middleware/write)
- [Microsoft Learn — Routing in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/routing)
- [Microsoft Learn — Static files in ASP.NET Core](https://learn.microsoft.com/aspnet/core/fundamentals/static-files)

---

**Criado por Fábio Cerqueira**
