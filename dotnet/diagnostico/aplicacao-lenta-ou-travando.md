# "A aplicação está lenta" ou "travou" — roteiro de diagnóstico

> Antes de culpar o banco: em boa parte dos casos o gargalo está no processo .NET, e a
> assinatura mais comum é **CPU baixa com aplicação parada** — threads bloqueadas
> esperando I/O.

| | |
|---|---|
| **Sintoma** | Aplicação lenta, travada, ou consumindo memória sem parar |
| **Compatibilidade** | .NET 8 / .NET 10 (ferramentas `dotnet-*`) · notas para .NET Framework |
| **Impacto do diagnóstico** | Baixo; a captura de dump congela o processo por alguns segundos |

---

## Passo 0 — As três perguntas

1. **Mudou alguma coisa?** Deploy, configuração, volume, integração nova.
2. **É tudo ou uma tela só?** Uma tela aponta para uma operação; tudo aponta para recurso
   compartilhado.
3. **Quando começou exatamente?** O horário preciso permite correlacionar com a pergunta 1.

---

## Passo 1 — Ler o padrão de CPU e memória

| CPU | Memória | Leitura mais provável | Vá para |
|---|---|---|---|
| **Baixa** | Estável | **Threads bloqueadas** esperando I/O | Passo 2 |
| Alta | Estável | Trabalho de CPU, ou GC excessivo | Passo 3 |
| Baixa | **Crescendo** | Vazamento de memória | Passo 4 |
| Alta | Crescendo | Pressão de GC por alocação | Passos 3 e 4 |
| Baixa | Estável, banco ocupado | O gargalo está no banco | [`../../sql-server/troubleshooting/`](../../sql-server/troubleshooting/) |

A primeira linha é a mais frequente e a mais contraintuitiva: **a aplicação parece ociosa e
está completamente travada.**

---

## Passo 2 — Esgotamento do pool de threads

Quando threads do pool ficam **bloqueadas** esperando I/O, o runtime cria novas devagar. A
fila cresce, a latência dispara, e a CPU continua baixa.

```bash
dotnet tool install --global dotnet-counters

dotnet-counters monitor --process-id <PID> --counters System.Runtime
```

| Contador | Sinal de problema |
|---|---|
| `ThreadPool Thread Count` | Crescendo continuamente |
| `ThreadPool Queue Length` | Alto e não baixa |
| `ThreadPool Completed Work Item Count` | Praticamente parado |
| `% Time in GC` | Acima de 20% de forma sustentada |

Esse conjunto confirma o diagnóstico. A causa quase sempre é uma destas:

| Causa | Onde ler |
|---|---|
| `.Result` / `.Wait()` em caminho de requisição | [`../async-await/armadilhas-async-await.md`](../async-await/armadilhas-async-await.md) |
| Chamada síncrona de banco dentro de código assíncrono | [`../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md`](../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md) |
| Pool de conexão esgotado segurando requisições | [`../../acesso-a-dados/ado-net/connection-pool-esgotado.md`](../../acesso-a-dados/ado-net/connection-pool-esgotado.md) |
| Query lenta no banco | [`../../sql-server/performance/`](../../sql-server/performance/) |

Procure no código por `.Result`, `.Wait()` e `.GetAwaiter().GetResult()` fora de `Main` e
de construtores. Cada ocorrência é uma thread bloqueada por requisição.

---

## Passo 3 — CPU alta

```bash
dotnet tool install --global dotnet-trace

# Coleta um perfil de CPU por 30 segundos
dotnet-trace collect --process-id <PID> --duration 00:00:30 \
    --profile cpu-sampling --output perfil.nettrace
```

O arquivo `.nettrace` abre no Visual Studio ou no PerfView e mostra onde o tempo de CPU foi
gasto, método a método.

Suspeitos por ordem de frequência:

1. **Serialização em excesso** — objeto grande serializado a cada requisição, ou
   `JsonSerializerOptions` recriado a cada chamada.
2. **Regex sem compilação nem timeout**, ou com retrocesso catastrófico.
3. **Laço sobre coleção grande** onde caberia um dicionário.
4. **GC** — se `% Time in GC` estiver alto, o problema é alocação, não cálculo.
5. **Criptografia** aplicada mais vezes do que o necessário.

> Confirme antes se a CPU alta é do **seu** processo. Antivírus, agente de monitoração e
> backup competem pelo mesmo processador e são frequentemente os culpados.

---

## Passo 4 — Memória crescendo

```bash
dotnet tool install --global dotnet-dump

# Captura o dump (o processo congela por alguns segundos)
dotnet-dump collect --process-id <PID> --output dump1.dmp

# Aguarde e capture um segundo, para comparar o crescimento
dotnet-dump collect --process-id <PID> --output dump2.dmp

# Analisar
dotnet-dump analyze dump1.dmp
```

Dentro do analisador:

```text
> dumpheap -stat
   ... lista os tipos por quantidade e bytes ocupados ...

> gcroot <endereco>
   ... mostra QUEM esta segurando aquele objeto ...
```

`dumpheap -stat` nos dois dumps revela o tipo que cresceu. `gcroot` responde a pergunta
que importa: **quem impede a coleta**.

### Suspeitos habituais

| Suspeito | Sintoma no dump |
|---|---|
| `HttpClient` criado em laço | Muitas instâncias de handler e de socket |
| Conexões de banco não descartadas | Muitos `SqlConnection` vivos |
| `DbContext` singleton | Milhares de entidades rastreadas |
| Cache estático sem limite nem expiração | Um dicionário enorme na raiz estática |
| Evento assinado e nunca liberado | O publicador segura os assinantes |
| `IDisposable` sem `Dispose` | Objetos na fila de finalização |

> **Em .NET Framework** as ferramentas `dotnet-*` não se aplicam. Use **DebugDiag** ou
> **ProcDump** para capturar, e **WinDbg** com **SOS** para analisar. Os comandos
> `!dumpheap -stat` e `!gcroot` são os mesmos.

---

## Passo 5 — Onde as requisições estão presas

Quando a aplicação está no IIS, um comando responde em uma linha:

```powershell
& "$env:SystemRoot\System32\inetsrv\appcmd.exe" list requests /elapsed:5000
```

Ele lista as requisições em execução há mais de cinco segundos, com URL, verbo, tempo e o
**módulo/estágio** em que estão — dizendo direto se o gargalo está na aplicação, no banco
ou em uma chamada externa.

Veja [`../../iis/troubleshooting/http-503-service-unavailable.md`](../../iis/troubleshooting/http-503-service-unavailable.md).

---

## Passo 6 — Confirmar do lado do banco

```sql
-- Quantas sessoes esta aplicacao mantem, e quantas estao ativas?
-- ../../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql
```

| Achado no banco | Leitura |
|---|---|
| Muitas sessões `sleeping` da aplicação | Vazamento de conexão |
| Sessões com `blocking_session_id` preenchido | Bloqueio — [`../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql`](../../sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) |
| Espera `ASYNC_NETWORK_IO` alta | **O banco terminou e a aplicação não consome o resultado.** O problema é aqui, não lá |
| Banco ocioso | O gargalo é no processo .NET — volte ao Passo 2 |

A terceira linha é a que mais gera discussão entre time de aplicação e time de banco.
`ASYNC_NETWORK_IO` alto quase nunca é "rede lenta": significa que a aplicação pediu um
resultado grande e está processando linha a linha enquanto o SQL Server segura o restante.

---

## Árvore de decisão

```text
"A aplicacao esta lenta"
│
├─ CPU baixa, memoria estavel
│   ├─ ThreadPool Queue Length alto  -> threads bloqueadas (.Result/.Wait)
│   ├─ Muitas sessoes no banco       -> pool de conexao esgotado
│   └─ Banco ocioso e fila vazia     -> rede, ou o gargalo esta antes da aplicacao
│
├─ CPU alta
│   ├─ % Time in GC alto             -> alocacao excessiva
│   └─ Perfil aponta um metodo       -> otimizar aquele caminho
│
├─ Memoria crescendo
│   └─ dumpheap + gcroot             -> achar quem segura o objeto
│
└─ Banco ocupado
    └─ ../../sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md
```

---

## Ferramentas, em resumo

| Ferramenta | Para quê | Plataforma |
|---|---|---|
| `dotnet-counters` | Métricas ao vivo (thread pool, GC, exceções) | .NET Core 3.0+ |
| `dotnet-trace` | Perfil de CPU e eventos | .NET Core 3.0+ |
| `dotnet-dump` | Captura e análise de dump | .NET Core 3.0+ |
| `dotnet-gcdump` | Snapshot só do heap gerenciado, mais leve | .NET Core 3.0+ |
| **ProcDump** / **DebugDiag** | Captura de dump | .NET Framework |
| **WinDbg** + **SOS** | Análise de dump | .NET Framework |
| **PerfView** | Análise de trace e de alocação | Ambos |
| `appcmd list requests` | Requisições presas agora | IIS |

Instale as ferramentas `dotnet-*` **antes** de precisar delas. Durante um incidente, com o
servidor sem acesso à internet, não dá tempo.

---

## O que registrar antes de reiniciar

Reiniciar o processo resolve o minuto seguinte e **destrói toda a evidência**. Antes:

- [ ] captura de `dotnet-counters` (ou dos contadores de desempenho);
- [ ] um **dump** do processo;
- [ ] saída de `appcmd list requests`;
- [ ] estado das sessões no banco;
- [ ] horário exato e o que estava acontecendo.

Sem isso, a reunião de pós-incidente termina em "reiniciamos e melhorou" — o que garante a
reincidência.

## Referências

- [Ferramentas de diagnóstico do .NET](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/)
- [`dotnet-counters`](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/dotnet-counters)
- [`dotnet-dump`](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/dotnet-dump)
- [Depurar vazamento de memória](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/debug-memory-leak)
- [Depurar alto uso de CPU](https://learn.microsoft.com/pt-br/dotnet/core/diagnostics/debug-highcpu)

---

**Criado por Fábio Cerqueira**
