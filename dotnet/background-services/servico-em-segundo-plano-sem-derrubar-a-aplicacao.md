# Serviço em segundo plano sem derrubar a aplicação

> `BackgroundService` que morre calado, API inteira que cai por causa de um job, `DbContext`
> descartado, processamento duplicado quando sobe a segunda instância.

| | |
|---|---|
| **Compatibilidade** | `Microsoft.Extensions.Hosting` — .NET Core 3.1+ e .NET 5+. Seção final trata do .NET Framework. |
| **Impacto** | **Alto.** Exceção não tratada aqui derruba o processo inteiro. |

---

## As quatro armadilhas

1. **Exceção não tratada derruba o host.** O padrão atual de
   `HostOptions.BackgroundServiceExceptionBehavior` é `StopHost`: um erro no job noturno tira a API
   do ar. Em versões antigas do host o padrão era ignorar — igualmente ruim, porque o serviço
   morria em silêncio.
2. **`DbContext` no construtor.** `BackgroundService` é singleton; o contexto fica cativo — ver
   [tempos-de-vida-e-dependencia-cativa.md](../dependency-injection/tempos-de-vida-e-dependencia-cativa.md).
3. **`CancellationToken` ignorado**, o que impede o encerramento limpo.
4. **Duas instâncias processando a mesma coisa** quando a aplicação é escalada.

---

## Solução de referência

```csharp
public sealed class ProcessadorDeIntegracao : BackgroundService
{
    private readonly IServiceScopeFactory _fabricaDeEscopo;
    private readonly ILogger<ProcessadorDeIntegracao> _logger;

    public ProcessadorDeIntegracao(
        IServiceScopeFactory fabricaDeEscopo,
        ILogger<ProcessadorDeIntegracao> logger)
    {
        _fabricaDeEscopo = fabricaDeEscopo;
        _logger          = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken parada)
    {
        _logger.LogInformation("Processador de integracao iniciado.");

        // PeriodicTimer (.NET 6+) nao acumula execucoes atrasadas,
        // ao contrario de System.Threading.Timer.
        using var temporizador = new PeriodicTimer(TimeSpan.FromSeconds(30));

        while (!parada.IsCancellationRequested)
        {
            try
            {
                await ProcessarLoteAsync(parada);
            }
            catch (OperationCanceledException) when (parada.IsCancellationRequested)
            {
                // Encerramento normal. Nao e erro.
                break;
            }
            catch (Exception excecao)
            {
                // Captura ampla DE PROPOSITO: o ciclo precisa sobreviver
                // a falha de um lote. Sem isso, o host inteiro cai.
                _logger.LogError(excecao, "Falha ao processar lote. O ciclo continua.");
            }

            try
            {
                await temporizador.WaitForNextTickAsync(parada);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }

        _logger.LogInformation("Processador de integracao encerrado.");
    }

    private async Task ProcessarLoteAsync(CancellationToken cancellationToken)
    {
        // Escopo proprio por ciclo: o DbContext nasce e morre aqui.
        using var escopo = _fabricaDeEscopo.CreateScope();

        var contexto = escopo.ServiceProvider.GetRequiredService<MeuDbContext>();

        var pendentes = await contexto.Integracoes
            .Where(i => i.Status == StatusIntegracao.Pendente)
            .OrderBy(i => i.CriadoEm)
            .Take(100)
            .ToListAsync(cancellationToken);

        foreach (var item in pendentes)
        {
            cancellationToken.ThrowIfCancellationRequested();

            using (_logger.BeginScope(new Dictionary<string, object>
                   {
                       ["IntegracaoId"] = item.Id,
                       ["CorrelationId"] = item.CorrelationId
                   }))
            {
                try
                {
                    await EnviarAsync(item, cancellationToken);
                    item.Status = StatusIntegracao.Concluida;
                }
                catch (Exception excecao)
                {
                    // Falha de UM item nao derruba o lote inteiro.
                    _logger.LogError(excecao, "Falha ao enviar integracao.");

                    item.Tentativas++;
                    item.UltimoErro = excecao.Message;

                    if (item.Tentativas >= 5)
                        item.Status = StatusIntegracao.Falha;
                }
            }
        }

        await contexto.SaveChangesAsync(cancellationToken);
    }
}

// Registro
builder.Services.AddHostedService<ProcessadorDeIntegracao>();
```

---

## O que cada decisão resolve

**`catch (Exception)` dentro do laço.** Em quase todo o resto do sistema, captura ampla é um erro.
Aqui é o oposto: sem ela, uma falha transitória de rede derruba o processo. A regra que mantém isso
legítimo é **registrar sempre, nunca engolir em silêncio**.

**`when (parada.IsCancellationRequested)` no `OperationCanceledException`.** Sem essa condição, um
timeout de `HttpClient` — que também lança `OperationCanceledException` — seria confundido com
encerramento e o serviço pararia por engano.

**Escopo por ciclo, não por serviço.** O `DbContext` nasce e morre em cada volta. Um contexto vivo
por horas acumula o *change tracker* indefinidamente e segura conexão do pool.

**`PeriodicTimer`.** Se um ciclo demora mais que o intervalo, ele não enfileira execuções atrasadas
— problema clássico de `System.Threading.Timer`, que dispara callbacks sobrepostos e faz dois
ciclos competirem pelos mesmos registros.

**Falha por item, não por lote.** Um registro com dado inválido não pode impedir os outros 99. O
contador de tentativas evita reprocessamento infinito.

---

## Encerramento limpo

Quando a aplicação para, o host sinaliza o `CancellationToken` e **espera** — por padrão, 30
segundos, até o .NET 5; 5 segundos no host genérico mais recente, conforme a versão. Confirme o
padrão da sua e defina explicitamente:

```csharp
builder.Services.Configure<HostOptions>(opcoes =>
{
    opcoes.ShutdownTimeout = TimeSpan.FromSeconds(30);

    // Alternativa deliberada ao padrao StopHost, quando o servico e acessorio
    // e a aplicacao NAO deve cair junto com ele.
    // opcoes.BackgroundServiceExceptionBehavior =
    //     BackgroundServiceExceptionBehavior.Ignore;
});
```

> **Sobre `Ignore`:** ele impede que o job derrube a API, mas o serviço morre em silêncio e não
> volta. Se optar por ele, monitore explicitamente se o serviço continua vivo — um *health check*
> que verifica o horizonte da última execução bem-sucedida. Preferir o `try/catch` bem posicionado
> é quase sempre melhor: o ciclo sobrevive **e** o erro fica registrado.

Se o trabalho puder ser interrompido no meio, ele precisa ser **idempotente ou transacional**. O
padrão abaixo garante que um item interrompido volte a ser pendente:

```csharp
// Marca como "em processamento" com carimbo de tempo.
// Uma rotina de recuperacao devolve para Pendente o que ficou preso
// alem do tempo maximo esperado.
UPDATE dbo.Integracao
   SET Status = 'Pendente', ProcessandoDesde = NULL
 WHERE Status = 'Processando'
   AND ProcessandoDesde < DATEADD(MINUTE, -15, SYSUTCDATETIME());
```

---

## Múltiplas instâncias

Assim que a aplicação é escalada, **todas as instâncias rodam o mesmo `BackgroundService`**. Sem
coordenação, duas processam o mesmo registro.

### Opção 1 — Reivindicação atômica no banco (a mais simples e robusta)

```sql
-- Uma unica instrucao: seleciona e reivindica no mesmo passo.
-- READPAST pula linhas ja bloqueadas por outra instancia,
-- em vez de esperar por elas.
UPDATE TOP (100) i
   SET i.Status           = 'Processando',
       i.ProcessandoDesde = SYSUTCDATETIME(),
       i.ProcessadoPor    = @NomeDaInstancia
  OUTPUT inserted.Id, inserted.Payload
  FROM dbo.Integracao AS i WITH (READPAST, UPDLOCK, ROWLOCK)
 WHERE i.Status = 'Pendente';
```

`OUTPUT` devolve as linhas reivindicadas na mesma operação, sem janela de corrida entre ler e
marcar. `READPAST` exige índice adequado em `Status` para não degradar em varredura.

### Opção 2 — Lock distribuído

Um lock com expiração (`sp_getapplock` no SQL Server, ou Redis) elege uma instância como líder.
Simples de entender, e concentra o trabalho em um nó só — o que anula parte do benefício de
escalar.

### Opção 3 — Tirar o job da aplicação

 Um processo separado (Worker Service, container próprio, SQL Agent) com uma única instância
resolve o problema por desenho. Também separa o perfil de recurso: job pesado deixa de competir
por CPU com as requisições dos usuários.

---

## Quando NÃO usar `BackgroundService`

| Necessidade | Melhor opção |
|---|---|
| Rotina noturna de banco | SQL Agent Job — ver [`sql-server/administracao/`](../../sql-server/administracao/) |
| Trabalho pesado que compete com a API | Processo separado (Worker Service) |
| Agendamento complexo (cron, calendário, retentativa persistente) | Agendador dedicado |
| "Disparar e esquecer" após uma requisição | Fila persistente. `Task.Run` em requisição perde o trabalho no primeiro *recycle* do Application Pool |

> Em IIS, um Application Pool ocioso é desligado e reciclado periodicamente. Um
> `BackgroundService` hospedado ali **para junto**. Se o trabalho precisa acontecer independentemente
> de tráfego, ele não pertence à aplicação web. Ver [`iis/troubleshooting/`](../../iis/troubleshooting/).

---

## .NET Framework

Não existe `BackgroundService`. As opções:

- **Windows Service** (`ServiceBase`) — a equivalente direta e a mais adequada.
- **`HostingEnvironment.QueueBackgroundWorkItem`** (ASP.NET 4.5.2+) — registra o trabalho no
  runtime, que **espera** por ele antes de reciclar. Melhor que `Task.Run`, mas ainda limitado pelo
  tempo de encerramento e perdido em queda abrupta.
- **SQL Agent Job** chamando uma procedure ou um executável — muitas vezes a resposta certa quando
  o trabalho é essencialmente de banco.

---

## Checklist

- [ ] `try/catch` dentro do laço, com log — nunca captura silenciosa.
- [ ] `OperationCanceledException` distinguida de erro real por `when`.
- [ ] `IServiceScopeFactory` com escopo por ciclo; nenhum `DbContext` no construtor.
- [ ] `CancellationToken` propagado a **todas** as chamadas assíncronas.
- [ ] `PeriodicTimer` ou equivalente que não sobreponha execuções.
- [ ] Falha de um item não interrompe o lote; há contador de tentativas.
- [ ] Trabalho idempotente ou com rotina de recuperação de itens presos.
- [ ] Coordenação entre instâncias definida antes de escalar.
- [ ] `ShutdownTimeout` compatível com a duração de um ciclo.
- [ ] Health check que detecta serviço parado.
- [ ] Log de início e de encerramento — sem eles não se sabe se o serviço está vivo.

---

## Referências

- [Microsoft Learn — Worker Services in .NET](https://learn.microsoft.com/dotnet/core/extensions/workers)
- [Microsoft Learn — `BackgroundService`](https://learn.microsoft.com/dotnet/api/microsoft.extensions.hosting.backgroundservice)
- [Microsoft Learn — `HostOptions.BackgroundServiceExceptionBehavior`](https://learn.microsoft.com/dotnet/api/microsoft.extensions.hosting.hostoptions.backgroundserviceexceptionbehavior)
- [Microsoft Learn — `PeriodicTimer`](https://learn.microsoft.com/dotnet/api/system.threading.periodictimer)
- [Microsoft Learn — Table hints (`READPAST`, `UPDLOCK`)](https://learn.microsoft.com/sql/t-sql/queries/hints-transact-sql-table)

---

**Criado por Fábio Cerqueira**
