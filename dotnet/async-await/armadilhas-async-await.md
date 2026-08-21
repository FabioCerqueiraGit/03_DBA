# Armadilhas de `async`/`await` — deadlock, `async void` e sync-over-async

> `async`/`await` é simples de usar e fácil de usar errado. Os erros aqui listados não
> aparecem em desenvolvimento: aparecem em produção, sob carga, como travamento total.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8 · .NET 10 |
| **Impacto** | **Alto.** O sintoma clássico é a aplicação inteira parar de responder |

---

## 1. O deadlock clássico: `.Result` e `.Wait()`

### O sintoma

A requisição simplesmente **nunca responde**. Sem exceção, sem erro no log, sem CPU alta.
A thread fica pendurada para sempre. Em ASP.NET clássico, o pool de threads vai enchendo
até a aplicação inteira parar.

### O código que causa

```csharp
// ❌ DEADLOCK em ASP.NET (System.Web), WinForms e WPF
public ActionResult Index()
{
    var dados = ObterDadosAsync().Result;   // ou .Wait(), ou .GetAwaiter().GetResult()
    return View(dados);
}

private async Task<string> ObterDadosAsync()
{
    var resposta = await _http.GetStringAsync("https://<HOST-DA-API>/v1/dados");
    return resposta;
}
```

### Por que trava

1. `ObterDadosAsync` começa e chega no `await`.
2. Antes de suspender, o `await` **captura o `SynchronizationContext` atual**.
3. O método retorna uma `Task` incompleta.
4. `.Result` **bloqueia a thread da requisição**, esperando essa `Task`.
5. A chamada HTTP termina e o `await` tenta retomar **naquele contexto capturado**.
6. O contexto do ASP.NET clássico permite **uma thread por vez**, e essa thread está
   bloqueada no passo 4.

Deadlock perfeito: cada lado espera o outro.

### Onde acontece e onde não

| Plataforma | Tem `SynchronizationContext` que causa deadlock? |
|---|---|
| ASP.NET clássico (`System.Web`, WebForms, MVC 5) | **Sim** |
| WinForms | **Sim** |
| WPF | **Sim** |
| ASP.NET Core | Não |
| Console / worker service | Não |

Por isso o mesmo código "funciona no console de teste" e trava no WebForms. E por isso o
problema é tão comum em sistemas legados.

> **Atenção:** não haver deadlock em ASP.NET Core **não** torna `.Result` aceitável. Ele
> continua bloqueando uma thread do pool, o que sob carga leva a *thread pool starvation*:
> a aplicação fica lenta, a fila cresce, e a CPU nem parece ocupada.

### A correção

```csharp
// ✅ async ate o topo
public async Task<ActionResult> Index(CancellationToken cancellationToken)
{
    var dados = await ObterDadosAsync(cancellationToken).ConfigureAwait(false);
    return View(dados);
}
```

### Quando não dá para mudar a assinatura (legado)

Às vezes o método chamador é uma interface antiga, um handler do WebForms ou um ponto de
entrada que não pode virar `async`. Duas saídas, nesta ordem de preferência:

**A. `ConfigureAwait(false)` em toda a cadeia chamada**

```csharp
private async Task<string> ObterDadosAsync()
{
    // ConfigureAwait(false) faz a continuacao rodar em uma thread do pool,
    // sem tentar voltar ao contexto capturado. Assim o deadlock nao ocorre.
    var resposta = await _http.GetStringAsync(url).ConfigureAwait(false);
    return Processar(resposta);
}
```

A regra: **`ConfigureAwait(false)` precisa estar em todos os `await` da cadeia**. Um
único `await` sem ele já recria o deadlock.

**B. Isolar em uma thread do pool (último recurso)**

```csharp
// ⚠️ Funciona, mas desperdica uma thread. Use so quando A nao for possivel.
var dados = Task.Run(() => ObterDadosAsync()).GetAwaiter().GetResult();
```

`Task.Run` executa o delegate em uma thread do pool, que **não** tem
`SynchronizationContext` — a continuação não tenta voltar ao contexto travado.

Em ASP.NET clássico com .NET Framework 4.5+, também é possível habilitar o comportamento
mais moderno de contexto via `httpRuntime targetFramework="4.5"` (ou superior) no
`web.config`. Verifique o efeito antes de confiar nisso.

---

## 2. `ConfigureAwait(false)` — onde usar e onde não

| Tipo de código | Usar `ConfigureAwait(false)`? |
|---|---|
| **Biblioteca** (código reutilizável) | **Sim, sempre.** Você não sabe quem vai chamar |
| Camada de serviço e repositório | Sim |
| Aplicação WinForms/WPF, ao tocar em controles | **Não** — a continuação precisa da thread de UI |
| Controller de ASP.NET Core | Indiferente — não há contexto a capturar |
| Controller de ASP.NET clássico, se usa `HttpContext.Current` depois do `await` | **Não** — você perderia o contexto |

O último caso pega muita gente em legado: depois de `ConfigureAwait(false)`,
`HttpContext.Current` pode ser `null`. Capture o que precisar **antes** do `await`.

---

## 3. `async void` — exceção que derruba o processo

```csharp
// ❌ A excecao NAO pode ser capturada pelo chamador
public async void ProcessarPedido(Pedido pedido)
{
    await _servico.SalvarAsync(pedido);   // se lancar, derruba o processo
}

// ✅
public async Task ProcessarPedidoAsync(Pedido pedido, CancellationToken ct)
{
    await _servico.SalvarAsync(pedido, ct).ConfigureAwait(false);
}
```

Uma exceção em `async void` é relançada no `SynchronizationContext` e não tem `Task` para
carregá-la. O resultado costuma ser o encerramento do processo, com um log que não ajuda.

**Única exceção legítima:** manipuladores de evento (`button_Click`, por exemplo), onde a
assinatura é imposta pelo framework. Nesses casos, envolva o corpo inteiro em `try/catch`.

```csharp
private async void BotaoSalvar_Click(object sender, EventArgs e)
{
    try
    {
        await SalvarAsync();
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Falha ao salvar");
        MessageBox.Show("Nao foi possivel salvar. Tente novamente.");
    }
}
```

---

## 4. `Task.Run` para trabalho de I/O

```csharp
// ❌ Ocupa uma thread do pool so para ESPERAR I/O
var dados = await Task.Run(async () => await _http.GetStringAsync(url));

// ✅ I/O assincrono nao precisa de thread para esperar
var dados = await _http.GetStringAsync(url, cancellationToken);
```

`Task.Run` serve para trabalho **de CPU** que você quer tirar da thread atual — típico em
UI. Para I/O, ele só adiciona uma thread ociosa.

Em ASP.NET, `Task.Run` é ainda pior: você tira trabalho de uma thread do pool para dar a
outra thread do mesmo pool. Não há ganho de vazão, só troca de contexto.

---

## 5. Fire and forget sem tratamento

```csharp
// ❌ A Task e descartada. Se lancar, a excecao some.
_servico.EnviarEmailAsync(email);

// ❌ Um pouco melhor, mas continua sem tratar erro
_ = _servico.EnviarEmailAsync(email);
```

Em um processo web, trabalho disparado assim também pode ser interrompido no meio quando o
processo recicla — sem nenhum registro.

```csharp
// ✅ Fila persistente, worker dedicado (o certo)
await _fila.EnfileirarAsync(new EnvioDeEmail(email), cancellationToken);

// ✅ Se realmente precisar disparar em background no mesmo processo,
//    ao menos garanta que a excecao seja registrada.
_ = Task.Run(async () =>
{
    try
    {
        await _servico.EnviarEmailAsync(email, CancellationToken.None)
                      .ConfigureAwait(false);
    }
    catch (Exception ex)
    {
        _logger.LogError(ex, "Falha no envio de e-mail em background");
    }
});
```

Em ASP.NET Core, `IHostedService` e `BackgroundService` são os mecanismos certos para
trabalho de fundo dentro do processo. Para trabalho que **não pode ser perdido**, fila
externa.

---

## 6. `await` em sequência quando poderia ser em paralelo

```csharp
// ❌ 3 chamadas independentes, executadas uma apos a outra: 3 x latencia
var cliente  = await _api.ObterClienteAsync(id, ct);
var pedidos  = await _api.ObterPedidosAsync(id, ct);
var faturas  = await _api.ObterFaturasAsync(id, ct);

// ✅ Disparadas juntas: 1 x latencia (a maior delas)
var tarefaCliente = _api.ObterClienteAsync(id, ct);
var tarefaPedidos = _api.ObterPedidosAsync(id, ct);
var tarefaFaturas = _api.ObterFaturasAsync(id, ct);

await Task.WhenAll(tarefaCliente, tarefaPedidos, tarefaFaturas)
          .ConfigureAwait(false);

var cliente = await tarefaCliente;
var pedidos = await tarefaPedidos;
var faturas = await tarefaFaturas;
```

**Cuidados:**

- só vale quando as chamadas são **realmente independentes**;
- `Task.WhenAll` lança apenas a **primeira** exceção. Para ver todas, inspecione a
  `AggregateException` da task combinada;
- não paralelize contra o mesmo banco sem pensar: várias conexões simultâneas por
  requisição podem esgotar o pool. Veja
  [`../../acesso-a-dados/ado-net/connection-pool-esgotado.md`](../../acesso-a-dados/ado-net/connection-pool-esgotado.md);
- **`DbContext` do EF Core não é thread-safe.** Nunca dispare duas queries em paralelo no
  mesmo contexto.

---

## 7. `async` sem `await`

```csharp
// ⚠️ Gera aviso do compilador e roda de forma sincrona
public async Task<int> CalcularAsync(int a, int b)
{
    return a + b;
}

// ✅ Se nao ha I/O, nao precisa ser async
public Task<int> CalcularAsync(int a, int b) => Task.FromResult(a + b);

// ✅ Repasse simples: dispensa a maquina de estado
public Task<Pedido?> ObterAsync(int id, CancellationToken ct)
    => _repositorio.ObterAsync(id, ct);
```

No último caso há um detalhe: sem `async`/`await`, exceções lançadas **sincronamente**
dentro do método escapam antes de a `Task` existir, e o stack trace fica mais curto. Se o
método tiver validação de argumento, prefira manter `async`.

---

## Diagnosticar em produção

**Sintoma:** aplicação lenta ou travada, CPU baixa, sem erro no log.

Suspeite de *thread pool starvation*. Em ASP.NET Core, os contadores de eventos do runtime
expõem o tamanho e a fila do pool:

```bash
dotnet-counters monitor --process-id <PID> --counters System.Runtime
```

Observe `ThreadPool Thread Count` subindo continuamente e `ThreadPool Queue Length` alto.
Esse par indica threads bloqueadas esperando I/O — quase sempre `.Result`, `.Wait()` ou
chamada síncrona de banco dentro de código assíncrono.

Para achar a origem, procure no código por `.Result`, `.Wait()` e `.GetAwaiter().GetResult()`
fora de `Main` e de construtores.

---

## Checklist

- [ ] Nenhum `.Result` ou `.Wait()` em caminho de requisição.
- [ ] `ConfigureAwait(false)` em todo código de biblioteca e de serviço.
- [ ] Nenhum `async void`, exceto manipulador de evento com `try/catch`.
- [ ] `CancellationToken` recebido e propagado em todo método de I/O.
- [ ] Sem `Task.Run` envolvendo I/O.
- [ ] Chamadas independentes agrupadas com `Task.WhenAll` quando fizer sentido.
- [ ] Nenhuma query paralela no mesmo `DbContext`.
- [ ] Trabalho em background com registro de exceção, ou fila externa.

## Referências

- [Programação assíncrona em C#](https://learn.microsoft.com/pt-br/dotnet/csharp/asynchronous-programming/)
- [Padrão assíncrono baseado em tarefas (TAP)](https://learn.microsoft.com/pt-br/dotnet/standard/asynchronous-programming-patterns/task-based-asynchronous-pattern-tap)
- [`ConfigureAwait` — perguntas frequentes](https://devblogs.microsoft.com/dotnet/configureawait-faq/)

---

**Criado por Fábio Cerqueira**
