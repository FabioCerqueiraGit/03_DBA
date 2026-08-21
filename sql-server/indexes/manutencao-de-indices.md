# Manutenção de índices — `REBUILD`, `REORGANIZE` e o erro que quase toda rotina comete

> A maior parte das rotinas de manutenção de índice em produção gasta horas de janela
> resolvendo o problema errado. Este documento explica a diferença entre as duas
> operações, quando cada uma vale a pena, e o passo que quase sempre falta.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim, com ressalvas |
| **Impacto** | **Alto.** Gera I/O, transaction log e, conforme a opção, bloqueio |
| **Permissões** | `ALTER` no índice ou na tabela |

---

## O erro mais comum

```text
ALTER INDEX ... REBUILD      -> atualiza as estatisticas do indice, com FULLSCAN
ALTER INDEX ... REORGANIZE   -> NAO atualiza estatistica nenhuma
```

Muitas equipes migraram de `REBUILD` para `REORGANIZE` — decisão sensata, porque
`REORGANIZE` é online e mais barato — e **não acrescentaram um passo de
`UPDATE STATISTICS`**. O resultado é um banco cuja rotina de manutenção roda toda semana,
consome janela, e há anos não atualiza uma única estatística de índice.

Como o efeito é gradual, ninguém liga uma coisa à outra. O sintoma aparece como "a query
ficou lenta do nada".

**Se a sua rotina faz `REORGANIZE`, ela precisa de um passo separado de estatísticas.**
Veja [`../performance/estatisticas-desatualizadas.md`](../performance/estatisticas-desatualizadas.md).

---

## As duas operações, lado a lado

| | `REORGANIZE` | `REBUILD` |
|---|---|---|
| **O que faz** | Reordena as páginas do nível folha, no lugar | Recria o índice do zero |
| **Bloqueio** | Sempre online | `ONLINE = OFF` bloqueia; `ONLINE = ON` reduz muito |
| **Interrompível** | **Sim** — o trabalho já feito é mantido | Não — interromper reverte tudo |
| **Transaction log** | Pouco, e incremental | **Muito.** Em `FULL`, pode encher o disco de log |
| **Espaço extra** | Praticamente nenhum | Até ~1,2x o tamanho do índice (mais, se `ONLINE = ON`) |
| **Atualiza estatísticas** | **Não** | **Sim**, com `FULLSCAN` |
| **Aplica `FILLFACTOR` novo** | Não | Sim |
| **Níveis tratados** | Apenas a folha | O índice inteiro |
| **Edição** | Qualquer | `ONLINE = ON` exige edição compatível |

### Sintaxe

```sql
-- Reorganizar: online, barato, interrompivel
ALTER INDEX [IX_Pedido_ClienteId] ON dbo.Pedido REORGANIZE;

-- Reconstruir offline: mais rapido, mas BLOQUEIA a tabela
ALTER INDEX [IX_Pedido_ClienteId] ON dbo.Pedido
REBUILD WITH (ONLINE = OFF, SORT_IN_TEMPDB = ON, FILLFACTOR = 90);

-- Reconstruir online: exige edicao compativel; consome mais log e tempdb
ALTER INDEX [IX_Pedido_ClienteId] ON dbo.Pedido
REBUILD WITH (ONLINE = ON, SORT_IN_TEMPDB = ON, MAXDOP = 4);

-- Todos os indices de uma tabela
ALTER INDEX ALL ON dbo.Pedido REBUILD;
```

`SORT_IN_TEMPDB = ON` move a ordenação intermediária para o `tempdb`, reduzindo o
crescimento do arquivo de dados do banco. Em troca, exige espaço no `tempdb` — confirme
que há folga antes de usar em tabela grande.

---

## Quando fazer manutenção, e quando não fazer

### Quando vale

- Índice grande (a partir de alguns milhares de páginas) com fragmentação alta **e**
  varredura de intervalo frequente sobre ele.
- Densidade de página muito baixa: as páginas estão quase vazias, o índice ocupa mais
  espaço do que precisa e cada leitura traz menos linhas.
- Depois de uma carga muito grande, de uma migração ou de um `DELETE` massivo.

### Quando não vale

- **Índice pequeno.** Abaixo de ~1.000 páginas a fragmentação medida é ruído: o índice
  ocupa extensões mistas e o número alto não significa nada na prática.
- **Índice que ninguém lê.** Não reconstrua — avalie remover. Veja
  [`encontrar-indices-nao-utilizados.sql`](encontrar-indices-nao-utilizados.sql).
- **Armazenamento moderno com os dados em memória.** A fragmentação externa afeta
  principalmente a leitura sequencial vinda do disco. Com SSD e buffer pool bem
  dimensionado, o ganho é pequeno.
- **`REBUILD` semanal do banco inteiro, por reflexo.** Custa janela, gera volume enorme de
  transaction log e infla o backup de log, quase sempre sem contrapartida mensurável.

> A ordem de prioridade correta é: estatísticas atualizadas > remover índices inúteis >
> corrigir predicados não SARGable > criar o índice que falta > desfragmentar. A
> desfragmentação é a última da lista, e costuma receber a maior parte do esforço.

---

## Efeitos colaterais que pegam de surpresa

| Efeito | Detalhe |
|---|---|
| **Transaction log explode** | Em `FULL`, um `REBUILD` de tabela grande registra tudo. Já encheu muito disco de madrugada. Garanta backup de log durante a janela |
| **Availability Groups atrasam** | Todo esse log precisa ser replicado. Secundárias podem ficar para trás |
| **`tempdb` cresce** | Com `SORT_IN_TEMPDB = ON` |
| **Backup diferencial incha** | `REBUILD` marca como alteradas praticamente todas as páginas do índice. O diferencial da noite seguinte fica do tamanho de um full |
| **Cache de planos afetado** | Reconstruir invalida planos que dependem daquele índice — pico de recompilação logo depois |
| **`ONLINE = ON` não é sem bloqueio** | Ele reduz drasticamente o bloqueio, mas ainda exige locks de curta duração no início e no fim da operação |

Sobre o último ponto: a partir do SQL Server 2014 existe `WAIT_AT_LOW_PRIORITY`, que
permite definir o que fazer se esses locks finais não forem obtidos — esperar, abortar a
própria operação ou derrubar os bloqueadores. Vale conhecer antes de rodar `ONLINE = ON`
em horário movimentado.

---

## `FILLFACTOR`

`FILLFACTOR` define quanto espaço livre deixar em cada página na reconstrução.

| Valor | Efeito |
|---|---|
| `100` (padrão) | Páginas cheias. Ótimo para leitura; provoca *page split* em tabela com inserção no meio |
| `90` | Escolha razoável para tabela com escrita moderada |
| `70`–`80` | Para tabela com muita inserção fora da ordem da chave |

Cuidado com o excesso: `FILLFACTOR 70` significa que **30% de cada página está vazia** — em
disco, em backup e principalmente no buffer pool. Você troca memória útil por menos page
splits. Só vale quando os splits são realmente um problema medido.

Para chave crescente (`IDENTITY`, `datetime` de inserção), as inserções vão para o fim do
índice e não causam split no meio — aí `FILLFACTOR` baixo só desperdiça espaço.

---

## Uma rotina de manutenção que faz sentido

```text
1. Verificar fragmentacao        -> analisar-fragmentacao.sql (modo LIMITED)
2. Ignorar indices com menos de ~1000 paginas
3. Fragmentacao < 10%            -> nao fazer nada
4. Fragmentacao 10% a 30%        -> REORGANIZE
5. Fragmentacao > 30%            -> REBUILD
6. SEMPRE, apos REORGANIZE       -> UPDATE STATISTICS na tabela
7. Atualizar as estatisticas de coluna que o REBUILD nao cobre
```

O passo 6 é o que costuma faltar. O passo 7 também: `REBUILD` atualiza a estatística **do
índice reconstruído**, mas não as estatísticas de coluna criadas automaticamente
(`_WA_Sys_...`), que também influenciam planos.

### Sobre soluções prontas

Existem rotinas de manutenção de código aberto amplamente adotadas na comunidade de SQL
Server — a mais conhecida é a **SQL Server Maintenance Solution**, de Ola Hallengren. Elas
já tratam limiares, exclusão de índices pequenos, estatísticas, janela de tempo e registro
de execução.

Escrever a própria rotina do zero raramente compensa. Se optar por isso, cubra pelo menos:
limiar por tamanho, escolha entre `REORGANIZE` e `REBUILD`, atualização de estatísticas,
limite de janela e log do que foi feito.

---

## Azure SQL Database e Managed Instance

- Não há SQL Agent no Azure SQL Database; a automação vai por Elastic Jobs, Automation ou
  equivalente.
- O consumo de recursos da manutenção conta no limite de DTU/vCore contratado.
- A gestão de arquivos e log é do serviço, mas o custo de I/O da operação continua sendo
  seu.

## Referências

- [Reorganizar e reconstruir índices](https://learn.microsoft.com/pt-br/sql/relational-databases/indexes/reorganize-and-rebuild-indexes)
- [`ALTER INDEX`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/alter-index-transact-sql)
- [`sys.dm_db_index_physical_stats`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-db-index-physical-stats-transact-sql)
- [Operações de índice online](https://learn.microsoft.com/pt-br/sql/relational-databases/indexes/perform-index-operations-online)

---

**Criado por Fábio Cerqueira**
