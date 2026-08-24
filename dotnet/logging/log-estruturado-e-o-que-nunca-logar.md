# Log estruturado — níveis, templates e o que nunca registrar

> Log serve para responder perguntas em produção. A maior parte do log que se encontra por
> aí não responde pergunta nenhuma: é texto concatenado, sem contexto, impossível de
> filtrar — e, com frequência, contém dado que não deveria estar ali.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Pacotes** | `Microsoft.Extensions.Logging` · provedor (Serilog, NLog, console) |
| **Impacto** | Log mal dimensionado enche disco; log com dado pessoal é incidente de privacidade |

---

## O erro que anula todo o resto

```csharp
// ❌ Interpolacao: o log vira UMA STRING. Nao da para filtrar por pedido depois.
_logger.LogInformation($"Pedido {pedidoId} do cliente {clienteId} processado");

// ✅ Message template: os valores viram CAMPOS estruturados
_logger.LogInformation("Pedido {PedidoId} do cliente {ClienteId} processado",
    pedidoId, clienteId);
```

A diferença não é estética. Com o template, o provedor grava algo assim:

```json
{
  "@t": "2026-08-20T14:32:11.4Z",
  "@l": "Information",
  "@mt": "Pedido {PedidoId} do cliente {ClienteId} processado",
  "PedidoId": 48213,
  "ClienteId": 991,
  "CorrelationId": "7f3a..."
}
```

A partir daí você consulta `PedidoId = 48213` e encontra tudo que aconteceu com aquele
pedido. Com interpolação, resta procurar texto — e "procurar texto" em milhões de linhas
às três da manhã não é um plano.

Dois detalhes que fazem diferença na prática:

- **Nomeie os placeholders em `PascalCase`** e de forma consistente. `{PedidoId}` em todo
  o sistema, nunca `{pedidoId}` num lugar e `{IdDoPedido}` em outro — senão o campo não
  agrega.
- **A ordem dos argumentos é posicional**, não por nome. Trocar a ordem troca os valores
  silenciosamente.

---

## Os níveis, e quando usar cada um

| Nível | Use para | Em produção |
|---|---|---|
| `Trace` | Detalhe de execução passo a passo | **Nunca.** Pode conter dado sensível |
| `Debug` | Diagnóstico de desenvolvimento | Desligado; ligue temporariamente para investigar |
| `Information` | Fatos de negócio: pedido criado, integração enviada | **Ligado.** É o nível base |
| `Warning` | Algo estranho, mas a operação seguiu: retry, degradação, valor inesperado tratado | Ligado |
| `Error` | A operação **falhou**. Alguma coisa não aconteceu | Ligado, com alerta |
| `Critical` | O sistema está comprometido: não conecta no banco, cofre inacessível | Ligado, com alerta imediato |

Duas confusões comuns:

**`Warning` não é "erro pequeno".** É "deu certo, mas de um jeito que você deveria saber".
Um retry que funcionou na segunda tentativa é `Warning`. Um retry que esgotou as tentativas
é `Error`.

**Erro de validação do usuário não é `Error`.** CPF inválido digitado no formulário é
comportamento esperado do sistema. Se cada validação virar `Error`, o alerta perde o
significado e ninguém olha mais. Use `Information` ou `Debug`.

### Configuração por namespace

```json
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning",
      "Microsoft.EntityFrameworkCore.Database.Command": "Warning",
      "MinhaEmpresa.Integracoes": "Debug"
    }
  }
}
```

O padrão do ASP.NET Core registra cada requisição em `Information`, e o EF Core registra
**cada comando SQL**. Em produção isso enche disco rapidamente e afoga o que interessa —
daí o `Warning` nas duas linhas acima.

---

## Escopos — contexto sem repetir parâmetro

```csharp
using (_logger.BeginScope(new Dictionary<string, object>
{
    ["CorrelationId"] = correlationId,
    ["PedidoId"]      = pedido.Id,
    ["ClienteId"]     = pedido.ClienteId
}))
{
    _logger.LogInformation("Iniciando processamento");

    await _estoque.BaixarAsync(pedido, ct);
    _logger.LogInformation("Estoque baixado");

    await _fiscal.EmitirNotaAsync(pedido, ct);
    _logger.LogInformation("Nota emitida");
}
```

Todas as três mensagens saem carregando `CorrelationId`, `PedidoId` e `ClienteId`, sem que
você repita nada. É o mecanismo que transforma linhas soltas em uma **história**
rastreável.

> Nem todo provedor grava escopos por padrão. No console do ASP.NET Core, por exemplo, é
> preciso habilitar `IncludeScopes`. Confirme que o seu provedor está preservando os
> escopos — caso contrário você está pagando o custo sem colher o benefício.

---

## Performance — quando o log começa a custar

Cada chamada a `LogInformation` faz *boxing* dos argumentos e aloca. Em caminho de
altíssima frequência isso aparece no perfil.

### Verificar o nível antes de trabalho caro

```csharp
// ❌ A serializacao acontece MESMO com Debug desligado
_logger.LogDebug("Payload recebido: {Payload}", JsonSerializer.Serialize(objeto));

// ✅ So serializa se alguem for ler
if (_logger.IsEnabled(LogLevel.Debug))
    _logger.LogDebug("Payload recebido: {Payload}", JsonSerializer.Serialize(objeto));
```

Essa é uma das causas mais discretas de CPU alta: um `LogDebug` desligado que ainda assim
serializa um objeto grande a cada requisição.

### Gerador de código `[LoggerMessage]` (.NET 6+, C# 9+)

Para os caminhos mais quentes, o gerador cria o código sem alocação e já com a verificação
de nível embutida:

```csharp
internal static partial class LogDePedidos
{
    [LoggerMessage(
        EventId = 1001,
        Level   = LogLevel.Information,
        Message = "Pedido {PedidoId} do cliente {ClienteId} processado em {DuracaoMs}ms")]
    public static partial void PedidoProcessado(
        ILogger logger, int pedidoId, int clienteId, long duracaoMs);

    [LoggerMessage(
        EventId = 1002,
        Level   = LogLevel.Error,
        Message = "Falha ao processar o pedido {PedidoId}")]
    public static partial void FalhaAoProcessar(
        ILogger logger, int pedidoId, Exception excecao);
}
```

```csharp
// Uso
LogDePedidos.PedidoProcessado(_logger, pedido.Id, pedido.ClienteId, cronometro.ElapsedMilliseconds);
```

Regras do gerador: a classe e o método precisam ser `partial`, o método retorna `void`, e
os nomes de parâmetro não podem começar com sublinhado.

O **`EventId`** é um bônus subestimado: com ele você filtra por evento de negócio sem
depender do texto da mensagem — e o texto pode ser reescrito sem quebrar consulta nenhuma.

Em .NET Framework, o equivalente é `LoggerMessage.Define`, que existe desde as primeiras
versões de `Microsoft.Extensions.Logging` e aceita até seis parâmetros.

---

## Registrar exceção corretamente

```csharp
// ❌ Perde stack trace, inner exception e tipo
_logger.LogError("Erro: " + ex.Message);

// ❌ A excecao vira um parametro do template, nao o objeto de excecao
_logger.LogError("Falha ao processar {Erro}", ex);

// ✅ A excecao vai no PRIMEIRO parametro, fora do template
_logger.LogError(ex, "Falha ao processar o pedido {PedidoId}", pedido.Id);
```

A sobrecarga com `Exception` no primeiro parâmetro é o que faz o provedor gravar tipo,
mensagem, stack trace e toda a cadeia de `InnerException`. Sem ela, você grava uma frase
e joga fora o diagnóstico.

---

## O que **nunca** registrar

| Nunca | Por quê |
|---|---|
| Senha, mesmo errada | Usuários erram o campo e digitam a senha no login |
| Token, API key, client secret | Quem lê o log passa a ter o acesso |
| Número completo de cartão, CVV | Exigência contratual e regulatória |
| CPF, CNPJ, RG completos | Dado pessoal sob a LGPD |
| Dado de saúde, biometria, origem racial | Dado pessoal **sensível** sob a LGPD |
| Corpo inteiro de requisição ou resposta | Contém tudo acima sem você perceber |
| Connection string | Contém credencial |

**Registre o identificador, não o conteúdo.** `ClienteId = 991` responde a mesma pergunta
que o nome e o CPF do cliente, e não cria passivo.

Quando for indispensável registrar parte de um dado, mascare:

```csharp
public static string MascararDocumento(string? documento)
{
    if (string.IsNullOrWhiteSpace(documento) || documento.Length < 4)
        return "***";

    // Mantem apenas os 4 ultimos digitos: suficiente para conferencia,
    // insuficiente para identificar a pessoa.
    return new string('*', documento.Length - 4) + documento[^4..];
}
```

> `documento[^4..]` é sintaxe de C# 8+. Em .NET Framework com C# antigo, use
> `documento.Substring(documento.Length - 4)`.

### Os três vazamentos silenciosos

1. **`EnableSensitiveDataLogging` do EF Core** grava os **valores dos parâmetros** de toda
   query. Deixe-o condicionado ao ambiente de desenvolvimento. Veja
   [`../../acesso-a-dados/entity-framework-core/ef-core-performance.md`](../../acesso-a-dados/entity-framework-core/ef-core-performance.md).
2. **Rastreamento de mensagens do WCF** com `logEntireMessage="true"` grava o envelope SOAP
   inteiro, credenciais inclusas. Veja
   [`../../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md`](../../api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md).
3. **Exceção de banco** costuma trazer o comando e, quando a aplicação não parametriza, os
   valores literais junto. Mais um motivo para parametrizar:
   [`../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md`](../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md).

Log **é um sistema com dado sensível**. Ele merece controle de acesso, retenção definida e
expurgo — igual a qualquer banco.

---

## Provedores

`Microsoft.Extensions.Logging` é apenas a **abstração**. Quem grava é o provedor.

| Provedor | Quando |
|---|---|
| Console | Desenvolvimento; contêineres com coletor externo |
| **Serilog** | O mais adotado. Muitos destinos (*sinks*), bom suporte a log estruturado |
| **NLog** | Alternativa madura, forte em .NET Framework |
| Application Insights / OpenTelemetry | Quando já existe uma plataforma de observabilidade |
| EventLog do Windows | Serviço Windows sem infraestrutura de log |

Exemplo com Serilog em ASP.NET Core:

```csharp
builder.Host.UseSerilog((contexto, servicos, config) => config
    .ReadFrom.Configuration(contexto.Configuration)
    .ReadFrom.Services(servicos)
    .Enrich.FromLogContext()
    .Enrich.WithProperty("Aplicacao", "<NOME-DO-SISTEMA>")
    .WriteTo.Console()
    .WriteTo.File(
        path: "logs/aplicacao-.log",
        rollingInterval: RollingInterval.Day,
        retainedFileCountLimit: 30,
        shared: true));
```

`retainedFileCountLimit` não é detalhe: log sem rotação e sem retenção **enche o disco do
servidor** — e disco cheio derruba a aplicação e, se estiver no mesmo volume, o banco.

> Escreva o código contra `ILogger<T>`, não contra a API do Serilog. Assim o provedor vira
> uma decisão de configuração, não um acoplamento espalhado por todo o sistema.

---

## .NET Framework — o mesmo modelo

`Microsoft.Extensions.Logging` **funciona em .NET Framework**. Não é preciso migrar de
plataforma para ter log estruturado.

```csharp
// Em uma aplicacao .NET Framework sem container de DI
public static class Log
{
    public static ILoggerFactory Factory { get; } = LoggerFactory.Create(builder =>
    {
        builder.SetMinimumLevel(LogLevel.Information);
        builder.AddSerilog(new LoggerConfiguration()
            .WriteTo.File("logs/aplicacao-.log", rollingInterval: RollingInterval.Day)
            .CreateLogger());
    });

    public static ILogger<T> Para<T>() => Factory.CreateLogger<T>();
}
```

Em sistema legado, o maior ganho não é sofisticação — é **passar a existir log**. Comece
pelas fronteiras (entrada e saída de integração) e pelos `catch` que hoje engolem erro em
silêncio. Veja
[`../../sistemas-legados/modernizacao-incremental-strangler.md`](../../sistemas-legados/modernizacao-incremental-strangler.md).

---

## O que registrar de fato

Um log útil responde: **o quê**, **para quem**, **quando**, **quanto tempo** e **o que deu
errado**.

```csharp
// Fronteira de entrada
_logger.LogInformation(
    "Requisicao {Metodo} {Caminho} recebida. Correlation {CorrelationId}",
    metodo, caminho, correlationId);

// Decisao de negocio -- o "por que" que ninguem documenta
_logger.LogInformation(
    "Pedido {PedidoId} roteado para {Fluxo} por {Motivo}",
    pedido.Id, "aprovacao-manual", "valor acima do limite");

// Integracao externa, com duracao
_logger.LogInformation(
    "Chamada a {Servico} concluida em {DuracaoMs}ms com status {Status}",
    "api-fiscal", cronometro.ElapsedMilliseconds, (int)resposta.StatusCode);

// Falha, com a excecao no primeiro parametro
_logger.LogError(ex,
    "Falha ao emitir nota do pedido {PedidoId} na tentativa {Tentativa}",
    pedido.Id, tentativa);
```

A segunda linha é a mais valiosa e a mais rara: registrar **por que** o sistema tomou um
caminho. Seis meses depois, quando alguem perguntar "por que este pedido foi para
aprovação manual?", o log responde.

---

## Checklist

- [ ] Message template com placeholders nomeados — **zero** interpolação de string.
- [ ] Placeholders em `PascalCase`, consistentes em todo o sistema.
- [ ] Exceção sempre no **primeiro** parâmetro de `LogError`.
- [ ] Níveis usados com critério; validação de usuário não é `Error`.
- [ ] `Microsoft.AspNetCore` e `EntityFrameworkCore.Database.Command` em `Warning`.
- [ ] `IsEnabled` antes de serializar objeto para log.
- [ ] Escopo com `CorrelationId` na entrada de cada requisição.
- [ ] Provedor configurado com **rotação e retenção**.
- [ ] `EnableSensitiveDataLogging` fora de produção.
- [ ] Nenhuma senha, token, documento completo ou dado de saúde no log.
- [ ] Log tratado como sistema com dado sensível: acesso restrito e expurgo definido.

## Referências

- [Registro em log no C#](https://learn.microsoft.com/pt-br/dotnet/core/extensions/logging)
- [Log de alto desempenho](https://learn.microsoft.com/pt-br/dotnet/core/extensions/logging/high-performance-logging)
- [Geração de log em tempo de compilação](https://learn.microsoft.com/pt-br/dotnet/core/extensions/logger-message-generator)
- [Diretrizes de log para autores de biblioteca](https://learn.microsoft.com/pt-br/dotnet/core/extensions/logging/library-guidance)

---

**Criado por Fábio Cerqueira**
