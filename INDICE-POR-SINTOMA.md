# Índice por sintoma

> **Estou enfrentando um problema.** Encontre pelo sintoma, como ele chega até você — não
> pelo nome técnico da causa, que é justamente o que você ainda não sabe.
>
> Navegação: **Sintoma → Diagnóstico → Solução**

Para navegar por tecnologia, veja [`INDICE-POR-TECNOLOGIA.md`](INDICE-POR-TECNOLOGIA.md).

---

## Mapa rápido

```text
Estou enfrentando um problema...
│
├─ BANCO DE DADOS
│   ├─ O SQL Server esta lento
│   ├─ O banco esta bloqueado / travado
│   ├─ Existe deadlock
│   ├─ O transaction log esta crescendo
│   ├─ O tempdb encheu
│   ├─ O banco esta crescendo
│   ├─ Uma query ficou lenta
│   └─ O disco vai encher
│
├─ APLICACAO
│   ├─ A aplicacao esta lenta
│   ├─ A aplicacao travou (CPU baixa)
│   ├─ A memoria cresce ate reciclar
│   ├─ Nao consigo conectar no banco
│   └─ Funciona local e falha em producao
│
├─ API E INTEGRACAO
│   ├─ A API retorna timeout
│   ├─ A API retorna erro
│   ├─ O JSON nao desserializa
│   ├─ A chamada SOAP falha
│   ├─ Erro de certificado / TLS
│   └─ Operacao foi processada em duplicidade
│
└─ IIS E DEPLOY
    ├─ HTTP 503
    ├─ HTTP 500 / 502
    └─ O deployment falhou
```

---

## Banco de dados

### "O SQL Server está lento"

**Comece aqui:** [roteiro de diagnóstico em 8 passos](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md)

| Passo | Rode | Se... |
|---|---|---|
| Triagem | [`diagnostico-rapido-30-segundos.sql`](sql-server/troubleshooting/diagnostico-rapido-30-segundos.sql) | — |
| É bloqueio? | [`quem-esta-bloqueando-quem.sql`](sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) | Retornou linhas → bloqueio |
| É CPU? | [`queries-que-mais-consomem-cpu.sql`](sql-server/performance/queries-que-mais-consomem-cpu.sql) | Uma query domina → otimize-a |
| É I/O? | [`queries-que-mais-fazem-io.sql`](sql-server/performance/queries-que-mais-fazem-io.sql) | Lê muito e devolve pouco → falta índice |
| É memória? | [`memory-grants-e-fila-de-memoria.sql`](sql-server/monitoramento/memory-grants-e-fila-de-memoria.sql) | Linhas "NA FILA" → pressão de memória |
| Esperando o quê? | [`waits-em-tempo-real.sql`](sql-server/monitoramento/waits-em-tempo-real.sql) | — |

### "Quem está bloqueando quem?" / "o banco travou"

1. [`quem-esta-bloqueando-quem.sql`](sql-server/troubleshooting/quem-esta-bloqueando-quem.sql) — pares bloqueador/bloqueado, com o texto da query do bloqueador
2. [`arvore-de-bloqueio-hierarquica.sql`](sql-server/troubleshooting/arvore-de-bloqueio-hierarquica.sql) — **a sessão RAIZ**, que é a única que importa
3. [`encontrar-transacoes-abertas-longa-duracao.sql`](sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) — transação esquecida
4. Antes de matar a sessão: [`matar-sessao-com-seguranca.md`](sql-server/troubleshooting/matar-sessao-com-seguranca.md)

**Causa mais frequente:** transação aberta e abandonada pela aplicação. Correção definitiva
em [`ado-net-fundamentos-seguros.md`](acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md)
e [`timeout-de-comando-vs-conexao.md`](acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md).

### "Erro 1205 — deadlock"

1. [`extrair-deadlocks-do-system-health.sql`](sql-server/troubleshooting/extrair-deadlocks-do-system-health.sql) — os deadlocks já estão gravados
2. [`investigar-deadlocks.md`](sql-server/troubleshooting/investigar-deadlocks.md) — ler o grafo, achar o padrão, corrigir

> **Erro 1222** não é deadlock, é timeout de lock → trate como bloqueio.

### "O transaction log está crescendo"

1. [`por-que-o-transaction-log-esta-crescendo.md`](sql-server/troubleshooting/por-que-o-transaction-log-esta-crescendo.md)
2. [`diagnosticar-crescimento-transaction-log.sql`](sql-server/troubleshooting/diagnosticar-crescimento-transaction-log.sql)

> **Não** troque o recovery model para `SIMPLE` para resolver: isso quebra a cadeia de
> backup e elimina o restore point-in-time, em silêncio.

### "O tempdb encheu"

1. [`diagnosticar-tempdb.md`](sql-server/troubleshooting/diagnosticar-tempdb.md)
2. [`analisar-uso-do-tempdb.sql`](sql-server/troubleshooting/analisar-uso-do-tempdb.sql)

| Categoria dominante | Causa | Onde corrigir |
|---|---|---|
| Version store | Transação antiga aberta | [`encontrar-transacoes-abertas-longa-duracao.sql`](sql-server/troubleshooting/encontrar-transacoes-abertas-longa-duracao.sql) |
| Objetos internos | Spill por estimativa errada | [`estatisticas-desatualizadas.md`](sql-server/performance/estatisticas-desatualizadas.md) |
| Objetos de usuário | Tabelas temporárias grandes | Revisar o código |

### "Por que o banco está crescendo?"

1. [`tamanho-das-tabelas.sql`](sql-server/espaco-e-crescimento/tamanho-das-tabelas.sql)
2. [`tamanho-dos-indices.sql`](sql-server/espaco-e-crescimento/tamanho-dos-indices.sql)
3. [`espaco-em-disco-e-arquivos-do-banco.sql`](sql-server/monitoramento/espaco-em-disco-e-arquivos-do-banco.sql)

> Antes de `SHRINK`: [`shrink-quando-nao-usar.md`](sql-server/administracao/shrink-quando-nao-usar.md)

### "Essa query era rápida na semana passada"

| Suspeita | Onde ler |
|---|---|
| Estatística desatualizada | [`estatisticas-desatualizadas.md`](sql-server/performance/estatisticas-desatualizadas.md) |
| Parameter sniffing | [`parameter-sniffing.md`](sql-server/performance/parameter-sniffing.md) |
| Índice ausente ou removido | [`encontrar-indices-ausentes.sql`](sql-server/indexes/encontrar-indices-ausentes.sql) |
| Predicado não SARGable | [`sargability-e-indices-ignorados.md`](sql-server/performance/sargability-e-indices-ignorados.md) |
| Como ler o plano | [`como-ler-um-plano-de-execucao.md`](sql-server/performance/como-ler-um-plano-de-execucao.md) |

### "O índice existe mas o SQL Server não usa"

→ [`sargability-e-indices-ignorados.md`](sql-server/performance/sargability-e-indices-ignorados.md)

Causa muito frequente vinda da aplicação: `AddWithValue` gerando `NVARCHAR` contra coluna
`VARCHAR` → [`ado-net-fundamentos-seguros.md`](acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md).

---

## Aplicação

### "A aplicação está lenta" ou "travou"

**Comece aqui:** [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md)

| CPU | Memória | Provavelmente | Onde ir |
|---|---|---|---|
| **Baixa** | Estável | Threads bloqueadas | [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md) |
| Alta | Estável | Trabalho de CPU ou GC | [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) |
| Baixa | **Crescendo** | Vazamento | [`aplicacao-lenta-ou-travando.md`](dotnet/diagnostico/aplicacao-lenta-ou-travando.md) |
| Baixa | Estável, banco ocupado | O gargalo é o banco | [roteiro do SQL Server](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |

### "Timeout expired" ao conectar no banco

→ [`connection-pool-esgotado.md`](acesso-a-dados/ado-net/connection-pool-esgotado.md)

A mensagem culpa o banco; a causa quase sempre é conexão sem `Dispose` na aplicação.
Confirme do lado do banco com
[`sessoes-e-requests-em-execucao.sql`](sql-server/monitoramento/sessoes-e-requests-em-execucao.sql).

### "Timeout ao executar o comando"

→ [`timeout-de-comando-vs-conexao.md`](acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md)

Sempre por volta de 30 segundos? É o `CommandTimeout` no padrão. Antes de aumentá-lo,
verifique se não é bloqueio.

### "A página nunca responde" (sem erro, sem CPU)

→ [`armadilhas-async-await.md`](dotnet/async-await/armadilhas-async-await.md)

Deadlock por `.Result`/`.Wait()` em ASP.NET clássico, WinForms ou WPF.

### "Funciona local e falha em produção"

| Suspeita | Onde ler |
|---|---|
| TLS 1.2 não habilitado | [`legado-consumindo-api-rest-moderna.md`](sistemas-legados/legado-consumindo-api-rest-moderna.md) |
| Permissão na chave privada do certificado | [`consumir-soap-de-sistema-legado.md`](api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md) |
| Identidade do Application Pool sem permissão | [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md) |
| Configuração de ambiente diferente | [`http-500-e-http-502.md`](iis/troubleshooting/http-500-e-http-502.md) |
| Volume de dados muito maior | [roteiro do SQL Server](sql-server/troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md) |

---

## API e integração

### "A API retorna timeout"

→ [`timeout-e-cancellation.md`](dotnet/httpclient/timeout-e-cancellation.md)

São quatro timeouts na cadeia. A mensagem raramente diz qual estourou — o documento tem a
tabela para identificar.

### "A API funciona em teste e falha sob carga"

→ [`httpclient-uso-correto.md`](dotnet/httpclient/httpclient-uso-correto.md)

Esgotamento de portas por `HttpClient` criado em laço. Confirme com
`netstat -an | find /c "TIME_WAIT"` no servidor.

### "A integração falha de vez em quando"

→ [`resiliencia-retry-circuit-breaker.md`](dotnet/httpclient/resiliencia-retry-circuit-breaker.md)

### "O pedido foi processado em duplicidade"

→ [`retry-seguro-e-idempotencia.md`](api-integracao/resiliencia/retry-seguro-e-idempotencia.md)

Causa clássica: retry após timeout em operação não idempotente.

### "O JSON não desserializa"

→ [`serializacao-json.md`](dotnet/json/serializacao-json.md)

| Sintoma | Causa |
|---|---|
| Objeto com propriedades zeradas, **sem erro** | `PropertyNameCaseInsensitive` desligado |
| Data com horas de diferença | `DateTime.Kind` inadequado |
| Número rejeitado | Valor veio como string, ou cultura com vírgula |

### "A chamada SOAP falha"

→ [`consumir-soap-de-sistema-legado.md`](api-integracao/soap-wcf/consumir-soap-de-sistema-legado.md)

### "Could not create SSL/TLS secure channel"

→ [`legado-consumindo-api-rest-moderna.md`](sistemas-legados/legado-consumindo-api-rest-moderna.md)

TLS 1.2 não habilitado em .NET Framework. Uma linha resolve.

### "HTTP 401 / 403 na integração"

→ [`autenticacao-em-apis.md`](api-integracao/autenticacao/autenticacao-em-apis.md)

---

## IIS e deploy

### "HTTP 503 Service Unavailable"

→ [`http-503-service-unavailable.md`](iis/troubleshooting/http-503-service-unavailable.md)

O Application Pool está parado. O evento WAS no log **Sistema** diz por quê — e o motivo
mais comum é senha da identidade expirada.

### "HTTP 500.x" ou "HTTP 502.5"

→ [`http-500-e-http-502.md`](iis/troubleshooting/http-500-e-http-502.md)

**Anote o subcódigo.** `500.19` é configuração; `500.30` é falha de inicialização.

### "O deployment falhou"

→ [`checklist-deployment-aplicacao-dotnet.md`](checklists/checklist-deployment-aplicacao-dotnet.md)

---

## Sistemas legados

### "Sistema legado precisa consumir uma API REST moderna"

→ [`legado-consumindo-api-rest-moderna.md`](sistemas-legados/legado-consumindo-api-rest-moderna.md)

### "Precisamos modernizar sem parar o sistema"

→ [`modernizacao-incremental-strangler.md`](sistemas-legados/modernizacao-incremental-strangler.md)

### "O EF6 está gerando centenas de queries"

→ [`ef6-troubleshooting.md`](acesso-a-dados/entity-framework-6/ef6-troubleshooting.md)

Lazy loading vem **ligado por padrão** no EF6.

---

## Regra de ouro de qualquer incidente

> **Salve a evidência antes de mitigar.**

A cadeia de bloqueio, a transação aberta, o estado das threads e o conteúdo da memória
desaparecem no instante em que você mata a sessão ou reinicia o processo. Sem a evidência
salva, a reunião de pós-incidente termina em "reiniciamos e melhorou" — o que garante a
reincidência.

---

**Criado por Fábio Cerqueira**
