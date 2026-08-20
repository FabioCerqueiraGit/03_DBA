# "O tempdb encheu" / "o tempdb está lento"

> O `tempdb` é o rascunho compartilhado de toda a instância. Quando ele vira gargalo, a
> causa quase nunca está nele — está em quem o usa. Este documento separa os três tipos
> de consumo e aponta a correção de cada um.

| | |
|---|---|
| **Sintoma** | `tempdb` crescendo, erro 1105 no `tempdb`, esperas `PAGELATCH_UP` em `2:1:x` |
| **Compatibilidade** | SQL Server 2012+ (11.x) |
| **Impacto do diagnóstico** | Nenhum — somente leitura |
| **Permissões** | `VIEW SERVER STATE` |

---

## Problema

Um destes três sintomas:

1. **O `tempdb` cresce** até encher o disco, ou a instância retorna erro 1105
   (`Could not allocate space for object ... in database 'tempdb'`).
2. **Contenção de alocação**: várias sessões esperando em `PAGELATCH_UP` ou `PAGELATCH_EX`
   com `wait_resource` no formato `2:1:1`, `2:1:2` ou `2:1:3`.
3. **Lentidão generalizada** que acompanha operações de ordenação e junção.

**Rode:** [`analisar-uso-do-tempdb.sql`](analisar-uso-do-tempdb.sql)

---

## Os três consumidores, e o que cada um significa

O bloco 1 do script divide o consumo em três categorias. A categoria dominante define a
investigação inteira.

### 1. Version store alto

**O que é:** cópias de linhas mantidas para isolamento por versão de linha
(`READ_COMMITTED_SNAPSHOT`, `SNAPSHOT`), para triggers e para reconstrução online de
índice.

**O que significa:** existe uma **transação antiga aberta**. O SQL Server não pode
descartar versões enquanto alguma transação puder precisar delas. Uma transação de duas
horas segura duas horas de versões.

**Correção:** encontrar e encerrar a transação antiga —
[`encontrar-transacoes-abertas-longa-duracao.sql`](encontrar-transacoes-abertas-longa-duracao.sql).
Aumentar o `tempdb` não resolve: o crescimento continua enquanto a transação existir.

Nesse cenário é comum ver o transaction log crescendo ao mesmo tempo, pela mesma causa.

### 2. Objetos internos altos

**O que é:** estruturas de trabalho criadas pelo motor — ordenações, tabelas de hash,
spools, e o *spill* de operações que não couberam na memória concedida.

**O que significa:** o otimizador **estimou errado** quanta memória a query precisaria. O
sintoma aparece no `tempdb`, mas o problema é de estimativa de cardinalidade.

**Correção:** não é no `tempdb`. Na ordem:

1. atualizar estatísticas da(s) tabela(s) envolvida(s) — [`../performance/estatisticas-desatualizadas.md`](../performance/estatisticas-desatualizadas.md);
2. revisar índices que suportem a ordenação e a junção — [`../indexes/encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql);
3. revisar a query: `ORDER BY` desnecessário, `DISTINCT` compensando junção duplicada,
   `UNION` onde caberia `UNION ALL`;
4. verificar se há conversão implícita de tipo inflando a estimativa.

No plano de execução, o aviso de `spill` (operador com sinal de alerta) confirma o
diagnóstico.

### 3. Objetos de usuário altos

**O que é:** tabelas temporárias (`#tabela`), tabelas temporárias globais (`##tabela`) e
variáveis de tabela.

**O que significa:** o código está materializando volume no `tempdb`.

**Correção:** revisar o código.

- `SELECT ... INTO #temp` carregando milhões de linhas para depois filtrar — filtre antes;
- procedures longas que criam temporárias e não as descartam explicitamente em laço;
- variáveis de tabela grandes: por padrão, o otimizador estima **uma linha** para elas, o
  que produz planos ruins. Para volume relevante, prefira `#tabela`, que tem estatísticas.
  A partir do SQL Server 2019 há *table variable deferred compilation*, que melhora a
  estimativa, mas não elimina a diferença;
- `##tabelas` globais raramente se justificam e persistem além do esperado.

---

## Contenção de alocação (as páginas `2:1:x`)

Espera `PAGELATCH_UP` em `wait_resource` como `2:1:1`, `2:1:2` ou `2:1:3` é um problema
diferente: não é falta de espaço, é **fila para alocar** espaço.

| Recurso | Página | O que é |
|---|---|---|
| `2:1:1` | PFS | Page Free Space — controla espaço livre nas páginas |
| `2:1:2` | GAM | Global Allocation Map |
| `2:1:3` | SGAM | Shared Global Allocation Map |

O `2:` é o `database_id` do `tempdb`, que é sempre 2.

**Correção clássica:** múltiplos arquivos de **dados** no `tempdb`, todos com **o mesmo
tamanho inicial** e **o mesmo incremento de crescimento**. Tamanhos desiguais fazem o
algoritmo de preenchimento proporcional concentrar alocações no arquivo maior, anulando o
benefício.

Regra prática difundida: um arquivo por núcleo lógico até 8 núcleos; acima disso, avaliar
aumentos graduais medindo o efeito. Não há ganho em criar 64 arquivos por reflexo.

Notas de versão:

- a partir do **SQL Server 2016**, o instalador já sugere múltiplos arquivos de `tempdb` e
  alguns comportamentos que antes exigiam as trace flags **1117** e **1118** passaram a
  valer por padrão para o `tempdb`;
- em versões anteriores, essas trace flags eram a recomendação usual — verifique se ainda
  estão configuradas em instâncias antigas, e se ainda fazem sentido após uma atualização;
- o **arquivo de log** do `tempdb` continua sendo **um só**. Multiplicar log não traz
  benefício algum, em nenhum banco.

---

## Configuração que evita o problema

| Item | Recomendação | Por quê |
|---|---|---|
| Arquivos de dados | Múltiplos, **do mesmo tamanho** e mesmo incremento | Distribui a alocação e evita contenção |
| Arquivo de log | Apenas um | Log não se beneficia de múltiplos arquivos |
| Tamanho inicial | Dimensionado para o pico conhecido | Evita autogrow no meio do expediente |
| Crescimento | **MB fixo**, nunca percentual | Percentual gera arquivos desiguais ao longo do tempo |
| Disco | O mais rápido disponível, separado dos dados quando possível | `tempdb` é o banco mais escrito da instância |
| Localização | **Nunca** no mesmo volume do log de bancos de usuário críticos | Um enche o disco do outro |

O `tempdb` é recriado a cada restart da instância a partir do `model`, então mudanças de
tamanho e quantidade de arquivos só valem depois de reiniciar.

---

## Quando NÃO agir

- **Não aumente o `tempdb` antes de descobrir a categoria de consumo.** Você compra alguns
  dias e o problema volta.
- **Não encolha o `tempdb` em produção como rotina.** Ele volta ao tamanho no próximo
  restart; encolher com carga ativa pode gerar erro de alocação.
- **Não mova o `tempdb` para um volume qualquer só porque encheu.** Se ele encheu por
  version store, vai encher o volume novo também.

---

## Referências

- [Banco de dados tempdb](https://learn.microsoft.com/pt-br/sql/relational-databases/databases/tempdb-database)
- [`sys.dm_db_file_space_usage`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-db-file-space-usage-transact-sql)
- [`sys.dm_db_task_space_usage`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-db-task-space-usage-transact-sql)

---

**Criado por Fábio Cerqueira**
