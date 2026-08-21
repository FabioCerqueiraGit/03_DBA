# Autenticação em APIs — Basic, Bearer, JWT, OAuth 2.0 e certificados

> Cinco mecanismos, cada um adequado a um cenário. Escolher errado não costuma quebrar
> nada no dia do deploy — quebra depois, quando o token vaza ou expira em produção.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | Erro aqui é incidente de segurança, não de funcionalidade |

---

## Escolhendo o mecanismo

| Mecanismo | Use quando | Evite quando |
|---|---|---|
| **API Key** | Integração servidor a servidor, baixo risco | Precisa identificar **usuário**, ou expirar acesso |
| **Basic** | Legado que só oferece isso, **sempre sobre TLS** | Existe alternativa |
| **Bearer / JWT** | API moderna com identidade e escopo | Precisa revogar imediatamente (JWT vale até expirar) |
| **OAuth 2.0 client credentials** | Sistema chamando sistema, com credencial rotacionável | Cenário simples demais para o custo |
| **Certificado (mTLS)** | Instituição financeira, órgão público, alto valor | Não há processo de gestão e renovação de certificado |

---

## 1. API Key

```csharp
// Chave fixa do sistema: pode ficar em DefaultRequestHeaders
builder.Services.AddHttpClient<ClienteDaApi>((sp, client) =>
{
    var config = sp.GetRequiredService<IConfiguration>();

    client.BaseAddress = new Uri(config["ApiExterna:BaseUrl"]!);
    client.DefaultRequestHeaders.Add("X-API-Key", config["ApiExterna:ApiKey"]);
});
```

A chave vem de configuração — variável de ambiente, cofre de segredos, Key Vault. **Nunca**
do código nem de um `appsettings.json` versionado.

Limitações que precisam ser conhecidas: não expira sozinha, não identifica usuário, e
rotacionar exige coordenação com o parceiro. Trate como senha de serviço.

---

## 2. Basic Authentication

```csharp
var credenciais = Convert.ToBase64String(
    Encoding.UTF8.GetBytes($"{usuario}:{senha}"));

requisicao.Headers.Authorization =
    new AuthenticationHeaderValue("Basic", credenciais);
```

> **Base64 não é criptografia.** É codificação reversível: qualquer um que veja o tráfego
> lê o usuário e a senha. Basic **só** pode existir sobre HTTPS.

Cuidado com a codificação: alguns serviços legados esperam `ISO-8859-1` em vez de `UTF-8`
para senhas com acento. Se a autenticação falha só para certos usuários, teste as duas.

---

## 3. Bearer com JWT

### Consumindo

```csharp
requisicao.Headers.Authorization =
    new AuthenticationHeaderValue("Bearer", token);
```

> **Nunca** coloque um token de **usuário** em `DefaultRequestHeaders` de um `HttpClient`
> compartilhado: a instância é usada por várias requisições, e o token de um usuário pode
> ser enviado na chamada de outro. Sempre por requisição.

### Validando (API que você expõe)

```csharp
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.Authority = builder.Configuration["Jwt:Authority"];
        options.Audience  = builder.Configuration["Jwt:Audience"];

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer           = true,
            ValidateAudience         = true,
            ValidateLifetime         = true,
            ValidateIssuerSigningKey = true,

            // Padrao e 5 minutos de tolerancia. Reduza se o relogio for confiavel.
            ClockSkew = TimeSpan.FromSeconds(30)
        };
    });

var app = builder.Build();

app.UseAuthentication();   // SEMPRE antes de UseAuthorization
app.UseAuthorization();
```

**A ordem importa.** `UseAuthorization` antes de `UseAuthentication` faz toda requisição
chegar sem identidade — e a API rejeita tudo, ou pior, aceita tudo, dependendo da
política.

### O que um JWT é, e o que ele não é

```text
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9 . eyJzdWIiOiIxMjM0NSJ9 . <assinatura>
└─────── header ─────────────────┘   └── payload ──┘
```

As duas primeiras partes são **Base64Url, não criptografia**. Qualquer pessoa com o token
lê o conteúdo. A assinatura garante que ninguém **alterou** — não que ninguém **leu**.

Consequências práticas:

- **não coloque dado sensível no payload** (CPF completo, salário, dado de saúde);
- **não registre o token em log**: quem lê o log passa a ter o acesso;
- **JWT não é revogável**: uma vez emitido, vale até expirar. Se precisa de revogação
  imediata, use tokens curtos com refresh, ou uma lista de revogação consultada na
  validação.

---

## 4. OAuth 2.0 — client credentials

O fluxo para sistema chamando sistema, sem usuário no meio.

```csharp
public sealed class ProvedorDeToken
{
    private readonly HttpClient _http;
    private readonly IConfiguration _config;
    private readonly SemaphoreSlim _semaforo = new(1, 1);

    private string? _token;
    private DateTimeOffset _expiraEm = DateTimeOffset.MinValue;

    public ProvedorDeToken(HttpClient http, IConfiguration config)
    {
        _http = http;
        _config = config;
    }

    public async Task<string> ObterAsync(CancellationToken cancellationToken)
    {
        // Caminho rapido, sem bloquear
        if (_token is not null && DateTimeOffset.UtcNow < _expiraEm)
            return _token;

        await _semaforo.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Outra thread pode ter renovado enquanto esperavamos
            if (_token is not null && DateTimeOffset.UtcNow < _expiraEm)
                return _token;

            using var conteudo = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"]    = "client_credentials",
                ["client_id"]     = _config["OAuth:ClientId"]!,
                ["client_secret"] = _config["OAuth:ClientSecret"]!,
                ["scope"]         = _config["OAuth:Scope"]!
            });

            using var resposta = await _http
                .PostAsync(_config["OAuth:TokenEndpoint"], conteudo, cancellationToken)
                .ConfigureAwait(false);

            resposta.EnsureSuccessStatusCode();

            var payload = await resposta.Content
                .ReadFromJsonAsync<RespostaDeToken>(cancellationToken: cancellationToken)
                .ConfigureAwait(false)
                ?? throw new InvalidOperationException("Resposta de token vazia.");

            _token = payload.AccessToken;

            // Renove ANTES de expirar: uma margem evita a corrida com o relogio
            // do servidor de autorizacao e o tempo de rede.
            _expiraEm = DateTimeOffset.UtcNow
                        .AddSeconds(payload.ExpiresIn)
                        .AddMinutes(-2);

            return _token;
        }
        finally
        {
            _semaforo.Release();
        }
    }

    private sealed record RespostaDeToken(
        [property: JsonPropertyName("access_token")] string AccessToken,
        [property: JsonPropertyName("expires_in")]   int    ExpiresIn,
        [property: JsonPropertyName("token_type")]   string TokenType);
}
```

Três detalhes que evitam incidente:

1. **Cache do token.** Pedir um token novo a cada chamada sobrecarrega o servidor de
   autorização e costuma esbarrar em *rate limit*.
2. **Margem de renovação.** Renovar dois minutos antes evita a janela em que o token expira
   entre a validação local e a chegada da requisição ao servidor.
3. **Semaphore com dupla verificação.** Sem isso, cem requisições simultâneas com token
   expirado disparam cem pedidos de token ao mesmo tempo.

Para projetos maiores, considere bibliotecas dedicadas de gestão de token em vez de manter
esse código à mão.

### Aplicar o token automaticamente

```csharp
public sealed class HandlerDeAutenticacao : DelegatingHandler
{
    private readonly ProvedorDeToken _provedor;

    public HandlerDeAutenticacao(ProvedorDeToken provedor) => _provedor = provedor;

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var token = await _provedor.ObterAsync(cancellationToken).ConfigureAwait(false);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);

        return await base.SendAsync(request, cancellationToken).ConfigureAwait(false);
    }
}
```

```csharp
builder.Services.AddTransient<HandlerDeAutenticacao>();

builder.Services
    .AddHttpClient<ClienteDaApi>()
    .AddHttpMessageHandler<HandlerDeAutenticacao>()
    .AddStandardResilienceHandler();
```

---

## 5. Certificado de cliente (mTLS)

```csharp
builder.Services
    .AddHttpClient<ClienteDaApi>()
    .ConfigurePrimaryHttpMessageHandler(() =>
    {
        var handler = new SocketsHttpHandler
        {
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            SslOptions = new SslClientAuthenticationOptions
            {
                ClientCertificates = new X509CertificateCollection
                {
                    CarregarDoRepositorio("<THUMBPRINT>")
                }
            }
        };

        return handler;
    });

static X509Certificate2 CarregarDoRepositorio(string thumbprint)
{
    using var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);
    store.Open(OpenFlags.ReadOnly);

    var encontrados = store.Certificates.Find(
        X509FindType.FindByThumbprint, thumbprint, validOnly: false);

    return encontrados.Count > 0
        ? encontrados[0]
        : throw new InvalidOperationException(
            $"Certificado com thumbprint {thumbprint} nao encontrado.");
}
```

### Os três problemas de certificado, sempre os mesmos

| Problema | Sintoma | Correção |
|---|---|---|
| **Expirado** | Falha de um dia para o outro, sem deploy | Monitorar a validade e alertar com 30 dias de antecedência |
| **Sem permissão na chave privada** | Funciona na máquina do dev, falha no servidor | Conceder leitura da chave privada à conta do Application Pool ou do serviço |
| **Cadeia incompleta** | `UntrustedRoot` ou `PartialChain` | Instalar os certificados intermediários no servidor |

> **Nunca** desabilite a validação do certificado do servidor "para funcionar":
>
> ```csharp
> // ❌ Isto anula a protecao do TLS contra ataque de intermediario
> handler.SslOptions.RemoteCertificateValidationCallback = (_, _, _, _) => true;
> ```
>
> Se for absolutamente necessário em um ambiente de teste, restrinja ao ambiente e
> documente. Em produção, corrija a cadeia.

---

## Onde guardar segredo

| Ambiente | Onde |
|---|---|
| Desenvolvimento | *User Secrets* (`dotnet user-secrets`) — ficam fora do repositório |
| Servidor próprio | Variável de ambiente, ou arquivo com ACL restrita |
| Azure | Key Vault, com identidade gerenciada — sem senha nenhuma no código |
| Qualquer | **Nunca** em `appsettings.json` versionado |

Se um segredo vazou em um commit, considere-o comprometido e **rotacione**. Remover o
arquivo em um commit posterior não resolve: o valor continua no histórico do Git.

---

## Checklist

- [ ] HTTPS obrigatório em todos os ambientes.
- [ ] Segredos fora do código e fora do repositório.
- [ ] Token de usuário **por requisição**, nunca em `DefaultRequestHeaders`.
- [ ] Token cacheado com margem de renovação e proteção contra renovação concorrente.
- [ ] Nenhum token, senha ou chave em log.
- [ ] Nenhum dado sensível no payload do JWT.
- [ ] `UseAuthentication()` antes de `UseAuthorization()`.
- [ ] `ClockSkew` ajustado conscientemente.
- [ ] Validação de certificado **jamais** desabilitada em produção.
- [ ] Alerta de expiração de certificado configurado.
- [ ] Processo de rotação de credenciais definido e testado.

## Referências

- [Autenticação e autorização no ASP.NET Core](https://learn.microsoft.com/pt-br/aspnet/core/security/)
- [Autenticação JWT Bearer](https://learn.microsoft.com/pt-br/aspnet/core/security/authentication/configure-jwt-bearer-authentication)
- [Armazenamento seguro de segredos em desenvolvimento](https://learn.microsoft.com/pt-br/aspnet/core/security/app-secrets)
- [Certificados de cliente no ASP.NET Core](https://learn.microsoft.com/pt-br/aspnet/core/security/authentication/certauth)

---

**Criado por Fábio Cerqueira**
