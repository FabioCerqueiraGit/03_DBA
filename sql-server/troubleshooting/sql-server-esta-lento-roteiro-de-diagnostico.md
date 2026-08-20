# "O SQL Server está lento" — roteiro de diagnóstico

> Roteiro em oito passos para separar, em poucos minutos, **bloqueio** de **query ruim**
> de **problema de infraestrutura**. É o documento âncora da área de SQL Server: comece
> por aqui quando não souber por onde começar.

| | |
|---|---|
| **Sintoma** | "O sistema está lento", "o banco travou", "as telas não abrem" |
| **Compatibilidade** | SQL Server 2012+ (11.x). Observações para Azure SQL onde aplicável |
| **Impacto em produção** | Nenhum — todos os passos de diagnóstico são somente leitura |
| **Permissões** | `VIEW SERVER STATE` na instância |
| **Tempo** | 5 a 10 minutos até uma hipótese sustentada |

---

## Índice

- [Antes de qualquer coisa: três perguntas](#antes-de-qualquer-coisa-tr%C3%AAs-perguntas)
- [O que registrar antes de mitigar](#o-que-registrar-antes-de-mitigar)
- [Passo 1 — O servidor está mesmo ocupado?](#passo-1--o-servidor-est%C3%A1-mesmo-ocupado)
- [Passo 2 — É bloqueio?](#passo-2--%C3%A9-bloqueio)
- [Passo 3 — Existe transação aberta antiga?](#passo-3--existe-transa%C3%A7%C3%A3o-aberta-antiga)
- [Passo 4 — O servidor está esperando o quê?](#passo-4--o-servidor-est%C3%A1-esperando-o-qu%C3%AA)
- [Passo 5 — É CPU?](#passo-5--%C3%A9-cpu)
- [Passo 6 — É I/O?](#passo-6--%C3%A9-io)
- [Passo 7 — É memória?](#passo-7--%C3%A9-mem%C3%B3ria)
- [Passo 8 — Uma query específica regrediu?](#passo-8--uma-query-espec%C3%ADfica-regrediu)
- [Árvore de decisão](#%C3%A1rvore-de-decis%C3%A3o)
- [Mitigação imediata versus correção definitiva](#mitiga%C3%A7%C3%A3o-imediata-versus-corre%C3%A7%C3%A3o-definitiva)
- [O que NÃO fazer](#o-que-n%C3%A3o-fazer)
- [Referências](#refer%C3%AAncias)

---

## Antes de qualquer coisa: três perguntas

Faça estas perguntas **antes** de abrir o SSMS. Elas resolvem uma parte considerável dos
incidentes e custam trinta segundos.

**1. Mudou alguma coisa?**

Deploy, alteração de índice, patch de sistema operacional, atualização de driver, job novo,
carga de dados, cliente novo, campanha de marketing, fechamento de mês. Lentidão que começa
"do nada" quase sempre começa de alguma coisa. Pergunte ao time de aplicação e olhe o
histórico de deploy antes de olhar DMV.

**2. É todo mundo ou só um?**

| Alcance | Direção da investigação |
|---|---|
| Uma tela, um relatório, um cliente | Query específica ou parâmetro específico — vá para o **Passo 8** |
| Um servidor de aplicação de vários | Provavelmente não é o banco — verifique rede, pool de conexão e o próprio servidor |
| Todo mundo, ao mesmo tempo | Recurso compartilhado — **Passos 2, 4, 5, 6, 7** |

**3. Quando começou exatamente?**

Um horário preciso é a informação mais valiosa do incidente, porque permite correlacionar
com a resposta da pergunta 1. "Desde hoje de manhã" não serve; "desde 9h14" serve.

---

## O que registrar antes de mitigar

Quase toda mitigação destrói evidência. Se você matar a sessão bloqueadora, a investigação
morre junto com ela. Antes de qualquer ação corretiva, salve em arquivo:

1. A saída de [`diagnostico-rapido-30-segundos.sql`](diagnostico-rapido-30-segundos.sql) — captura o estado geral.
2. A saída de [`quem-esta-bloqueando-quem.sql`](quem-esta-bloqueando-quem.sql) — captura a cadeia de bloqueio, que desaparece em segundos.
3. O texto completo da query bloqueadora e o `session_id`, `login_name`, `host_name` e `program_name` dela.
4. O horário exato da coleta.

Sem isso, na reunião de pós-incidente a resposta será "não sabemos, mas matamos a sessão e
melhorou" — o que garante que o problema volte.

---

## Passo 1 — O servidor está mesmo ocupado?

Pode parecer óbvio, mas vale conferir: em uma parte dos chamados de "banco lento" o banco
está ocioso e o problema está na aplicação, no servidor web ou na rede.

**Rode:** [`diagnostico-rapido-30-segundos.sql`](diagnostico-rapido-30-segundos.sql)

**Interprete:**

| O que você vê | Significa | Vá para |
|---|---|---|
| Poucas ou nenhuma sessão ativa, sem espera relevante | O banco não é o gargalo | Investigue aplicação, IIS e rede — veja [`iis/troubleshooting/`](../../iis/troubleshooting/) |
| Muitas sessões com `blocking_session_id` diferente de zero | Bloqueio | **Passo 2** |
| Muitas sessões `RUNNABLE` | Fila por CPU | **Passo 5** |
| Sessões `SUSPENDED` esperando `PAGEIOLATCH_*` | Espera por disco | **Passo 6** |
| Sessões esperando `RESOURCE_SEMAPHORE` | Fila por concessão de memória | **Passo 7** |
| Uptime baixo (poucas horas) | A instância reiniciou; cache frio e DMVs zeradas | Considere isso na leitura de todos os passos |

> **Atenção ao uptime.** As DMVs de estatística acumulada (`sys.dm_os_wait_stats`,
> `sys.dm_exec_query_stats`, `sys.dm_db_index_usage_stats`) zeram no restart da instância.
> Com poucas horas de uptime, essas visões são pouco conclusivas.

---

## Passo 2 — É bloqueio?

Bloqueio é a causa mais frequente de "o sistema inteiro parou de repente", e é a mais
rápida de confirmar.

**Rode:** [`quem-esta-bloqueando-quem.sql`](quem-esta-bloqueando-quem.sql) e, se houver
cadeia longa, [`arvore-de-bloqueio-hierarquica.sql`](arvore-de-bloqueio-hierarquica.sql)

**Interprete:**

| Resultado | Significa |
|---|---|
| Nenhuma linha | Não há bloqueio neste instante. Não descarta bloqueio intermitente — repita algumas vezes |
| Uma sessão raiz bloqueando muitas | Caso clássico. Identifique a raiz e siga para o Passo 3 |
| Sessão raiz com `status = 'sleeping'` e `open_transaction_count > 0` | **Transação aberta e esquecida pela aplicação.** Vá para o Passo 3 |
| Cadeias curtas que aparecem e somem | Contenção normal sob carga. Trate como problema de query ou de índice: Passos 6 e 8 |

O detalhe que mais confunde: uma sessão bloqueadora com `status = 'sleeping'` e
`last_request_end_time` no passado **não está executando nada**. Ela abriu uma transação,
terminou o comando e não deu `COMMIT`. O banco está saudável; a aplicação é que está com
defeito. A causa quase sempre é uma destas:

- `TransactionScope` ou `SqlTransaction` sem `Dispose` em caminho de exceção;
- `BeginTransaction` seguido de chamada a serviço externo lenta dentro da transação;
- `CommandTimeout` estourado na aplicação sem rollback explícito;
- usuário que abriu transação manualmente no SSMS e foi almoçar.

Veja [`acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md`](../../acesso-a-dados/ado-net/timeout-de-comando-vs-conexao.md).

---

## Passo 3 — Existe transação aberta antiga?

**Rode:** [`encontrar-transacoes-abertas-longa-duracao.sql`](encontrar-transacoes-abertas-longa-duracao.sql)

Transação aberta há muito tempo causa três problemas ao mesmo tempo, e é comum tratar
apenas o primeiro:

1. **Bloqueia outras sessões** — o sintoma visível.
2. **Impede o truncamento do transaction log** — o log cresce até acabar o disco. Veja
   [`por-que-o-transaction-log-esta-crescendo.md`](por-que-o-transaction-log-esta-crescendo.md).
3. **Segura o version store no `tempdb`** quando há isolamento de versão de linha ativo —
   o `tempdb` cresce. Veja [`diagnosticar-tempdb.md`](diagnosticar-tempdb.md).

Se a transação mais antiga tem horas de idade, ela é a causa até prova em contrário.

---

## Passo 4 — O servidor está esperando o quê?

Toda sessão que não está usando CPU está esperando alguma coisa, e o SQL Server registra
exatamente o quê. Este é o passo que direciona a investigação.

**Rode:** [`../monitoramento/analisar-waits-acumulados.sql`](../monitoramento/analisar-waits-acumulados.sql)
para a visão desde o restart, e
[`../monitoramento/waits-em-tempo-real.sql`](../monitoramento/waits-em-tempo-real.sql)
para o que está acontecendo agora.

Prefira a visão em tempo real durante um incidente: a acumulada mistura o incidente com
semanas de operação normal e dilui o sinal.

**Principais famílias de espera:**

| Wait type | Leitura mais provável | Passo |
|---|---|---|
| `LCK_M_*` | Bloqueio por lock | **2** |
| `PAGEIOLATCH_SH`, `PAGEIOLATCH_EX` | Leitura de página do disco para memória — I/O ou falta de índice | **6** |
| `WRITELOG` | Gravação no transaction log — latência de disco do log ou transações muito pequenas em excesso | **6** |
| `SOS_SCHEDULER_YIELD` | Pressão de CPU | **5** |
| `CXPACKET`, `CXCONSUMER` | Paralelismo. Sozinho não é problema; acompanhado de outra espera indica onde olhar | **5** e **8** |
| `RESOURCE_SEMAPHORE` | Fila por concessão de memória | **7** |
| `PAGELATCH_UP` em `2:1:1` / `2:1:3` | Contenção de alocação no `tempdb` | [`diagnosticar-tempdb.md`](diagnosticar-tempdb.md) |
| `ASYNC_NETWORK_IO` | **O SQL terminou e a aplicação não consome o resultado.** O problema está na aplicação ou na rede, não no banco | Aplicação |
| `THREADPOOL` | Fila por worker thread. Situação grave, quase sempre consequência de bloqueio massivo | **2** |

> `ASYNC_NETWORK_IO` alto é um dos achados mais mal interpretados do SQL Server. Ele quase
> nunca significa "rede lenta". Na prática significa que a aplicação pediu um resultado
> grande e está processando linha a linha enquanto o SQL Server segura o restante. A
> correção é na aplicação: buscar menos dados, ou consumir o `SqlDataReader` sem
> processamento pesado no meio do laço.

---

## Passo 5 — É CPU?

**Confirme primeiro no sistema operacional.** Se a CPU total da máquina está em 90% mas o
processo `sqlservr.exe` está em 10%, o problema é outro processo — antivírus, backup,
agente de monitoração.

**Rode:** [`../performance/queries-que-mais-consomem-cpu.sql`](../performance/queries-que-mais-consomem-cpu.sql)

**Interprete:**

- **Uma query domina o consumo** → vá para o Passo 8. Provavelmente plano ruim, falta de
  índice ou parameter sniffing.
- **Consumo distribuído em muitas execuções de queries baratas** → o problema é volume de
  chamadas, não a query. Investigue a aplicação: laço `N+1`, falta de cache, ausência de
  paginação. Veja [`acesso-a-dados/entity-framework-core/ef-core-performance.md`](../../acesso-a-dados/entity-framework-core/ef-core-performance.md).
- **Muitas compilações por segundo** → possível ausência de parametrização. Cada execução
  gera plano novo e queima CPU no otimizador.

---

## Passo 6 — É I/O?

**Rode:** [`../performance/queries-que-mais-fazem-io.sql`](../performance/queries-que-mais-fazem-io.sql)
e [`../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql`](../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql)

Na maioria esmagadora dos casos, "problema de disco" no SQL Server é **problema de plano de
execução**. Uma query que faz varredura completa de uma tabela de 40 milhões de linhas
porque falta um índice gera I/O real e mede como gargalo de disco. Trocar o subsistema de
armazenamento resolve o sintoma por alguns meses; criar o índice resolve o problema.

Ordem de investigação:

1. Query com `logical_reads` desproporcional ao número de linhas retornadas → falta índice
   ou o predicado não é SARGable. Veja
   [`../performance/sargability-e-indices-ignorados.md`](../performance/sargability-e-indices-ignorados.md)
   e [`../indexes/encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql).
2. Latência real de disco por arquivo (`sys.dm_io_virtual_file_stats`) → se o log tem
   latência de escrita alta, olhe `WRITELOG` e o subsistema do arquivo `.ldf`.
3. Só depois disso, infraestrutura.

---

## Passo 7 — É memória?

**Rode:** [`../monitoramento/memory-grants-e-fila-de-memoria.sql`](../monitoramento/memory-grants-e-fila-de-memoria.sql)

Sinais de pressão de memória:

- Sessões esperando em `RESOURCE_SEMAPHORE`: há fila para conceder memória de execução.
- *Page Life Expectancy* caindo de forma abrupta e sustentada. O valor absoluto isolado diz
  pouco — o que importa é a **tendência** e a comparação com o comportamento normal daquela
  instância.
- Concessões de memória muito maiores que o uso real (`granted_memory_kb` muito acima de
  `used_memory_kb`): sintoma clássico de **estimativa de cardinalidade errada**, quase
  sempre por estatística desatualizada. Veja
  [`../performance/estatisticas-desatualizadas.md`](../performance/estatisticas-desatualizadas.md).

Antes de pedir mais RAM ao time de infraestrutura, confirme que `max server memory` está
configurado com um valor adequado — deixar o padrão em um servidor dedicado é um erro
comum e caro. Veja [`../administracao/README.md`](../administracao/README.md).

---

## Passo 8 — Uma query específica regrediu?

Chegando aqui, você já sabe que é uma query. Falta saber **qual** e **por quê**.

**Rode:** [`../performance/queries-mais-lentas-por-duracao.sql`](../performance/queries-mais-lentas-por-duracao.sql)

Se a instância tem **Query Store** ativo (SQL Server 2016+), use-o: ele é a ferramenta certa
para responder "essa query era rápida na semana passada, o que mudou?", porque guarda o
histórico de planos e permite comparar antes e depois.

Causas mais comuns de regressão súbita, em ordem de frequência:

| # | Causa | Como confirmar | Onde ler |
|---|---|---|---|
| 1 | Estatística desatualizada após crescimento de dados | Estimativa versus real muito diferentes no plano | [`estatisticas-desatualizadas.md`](../performance/estatisticas-desatualizadas.md) |
| 2 | Parameter sniffing — plano ótimo para um parâmetro, péssimo para outro | Mesma query, tempos muito diferentes por parâmetro | [`parameter-sniffing.md`](../performance/parameter-sniffing.md) |
| 3 | Índice removido, desabilitado ou nunca criado | Plano com `Scan` onde havia `Seek` | [`encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql) |
| 4 | Predicado não SARGable introduzido em um deploy | `Scan` apesar de o índice existir | [`sargability-e-indices-ignorados.md`](../performance/sargability-e-indices-ignorados.md) |
| 5 | Crescimento natural de volume sem revisão de índice | Tabela muito maior que na modelagem original | [`../espaco-e-crescimento/tamanho-das-tabelas.sql`](../espaco-e-crescimento/tamanho-das-tabelas.sql) |

Para ler o plano: [`../performance/como-ler-um-plano-de-execucao.md`](../performance/como-ler-um-plano-de-execucao.md).

---

## Árvore de decisão

```text
"O SQL Server está lento"
│
├─ Servidor ocioso, poucas sessões
│   └─ O gargalo não é o banco → aplicação, IIS, rede
│
├─ blocking_session_id preenchido em várias sessões
│   ├─ Sessão raiz "sleeping" com transação aberta
│   │   └─ Defeito na aplicação: transação sem COMMIT/ROLLBACK
│   └─ Sessão raiz executando algo pesado
│       └─ Otimizar a query da raiz (Passo 8)
│
├─ Espera predominante
│   ├─ LCK_M_*              → bloqueio (Passo 2)
│   ├─ PAGEIOLATCH_*        → I/O ou falta de índice (Passo 6)
│   ├─ WRITELOG             → latência do log ou transações pequenas demais
│   ├─ SOS_SCHEDULER_YIELD  → CPU (Passo 5)
│   ├─ RESOURCE_SEMAPHORE   → memória (Passo 7)
│   ├─ PAGELATCH_UP em 2:1:x→ contenção de tempdb
│   ├─ THREADPOOL           → esgotamento de workers, quase sempre efeito de bloqueio
│   └─ ASYNC_NETWORK_IO     → aplicação não consome o resultado
│
└─ Nada disso, mas uma query específica está lenta
    └─ Passo 8: estatística, parameter sniffing, índice, SARGability
```

---

## Mitigação imediata versus correção definitiva

| | Mitigação | Correção |
|---|---|---|
| **O que faz** | Devolve o sistema ao ar agora | Elimina a causa |
| **Exemplo** | `KILL` na sessão bloqueadora raiz | Corrigir a transação sem `COMMIT` na aplicação |
| **Risco** | Rollback longo, perda de trabalho em andamento, reincidência garantida | Exige deploy e janela |
| **Quando escolher** | Sistema parado, prejuízo por minuto | Sempre, depois da mitigação |

Mitigar é legítimo. O erro é parar na mitigação. Se você matou a sessão e não abriu um item
para corrigir a causa, você agendou o próximo incidente.

Antes de qualquer `KILL`, leia
[`matar-sessao-com-seguranca.md`](matar-sessao-com-seguranca.md) — matar a sessão errada
transforma um incidente de lentidão em um incidente de indisponibilidade, e um rollback
grande pode demorar mais que o bloqueio original.

---

## O que NÃO fazer

Ações frequentemente tentadas sob pressão que pioram a situação:

| Ação | Por que piora |
|---|---|
| **Reiniciar a instância** | Destrói toda a evidência (DMVs zeram), esvazia o cache de planos e provoca rollback de tudo que estava aberto. O sistema volta pior por vários minutos e você perde a chance de descobrir a causa |
| **Sair adicionando `WITH (NOLOCK)` nas queries** | Não corrige nada; troca o bloqueio por leitura suja, leitura duplicada e leitura ausente. Você passa a ter resultado errado rápido em vez de resultado certo lento |
| **`DBCC FREEPROCCACHE`** | Sob a desculpa de "limpar o cache", força recompilação de **todos** os planos e provoca pico de CPU no pior momento possível |
| **`DBCC SHRINKDATABASE` para "melhorar a performance"** | Fragmenta todos os índices e gera I/O intenso. Piora a performance de forma duradoura. Veja [`../administracao/shrink-quando-nao-usar.md`](../administracao/shrink-quando-nao-usar.md) |
| **`UPDATE STATISTICS` em todo o banco no meio do pico** | Pode ajudar, mas o custo de I/O e CPU durante a varredura costuma aprofundar o incidente. Faça direcionado, na tabela suspeita |
| **Criar todos os índices sugeridos pelo `sys.dm_db_missing_index_details`** | As sugestões são estimativas sem consciência umas das outras. Aplicá-las em bloco cria índices redundantes que penalizam toda escrita. Veja [`../indexes/encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql) |
| **Matar sessões em série até melhorar** | Você pode matar a vítima em vez do bloqueador, ou disparar um rollback de trinta minutos |

---

## Referências

- [Monitorar e ajustar o desempenho — SQL Server](https://learn.microsoft.com/pt-br/sql/relational-databases/performance/monitor-and-tune-for-performance)
- [`sys.dm_exec_requests`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-exec-requests-transact-sql)
- [`sys.dm_os_wait_stats`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql)
- [Query Store](https://learn.microsoft.com/pt-br/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store)

---

**Criado por Fábio Cerqueira**
