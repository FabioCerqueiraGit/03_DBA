# Estatísticas desatualizadas — a causa nº 1 de "ficou lento do nada"

> O otimizador do SQL Server decide o plano com base em **estimativas**. As estimativas
> vêm das estatísticas. Estatística velha produz estimativa errada, e estimativa errada
> produz plano ruim — mesmo com todos os índices no lugar.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012 SP1+ (11.x SP1) · Azure SQL Database: sim |
| **Impacto do diagnóstico** | Nenhum |
| **Impacto da correção** | **Médio a alto.** `UPDATE STATISTICS` gera I/O e invalida planos |
| **Permissões** | `VIEW DATABASE STATE`; `ALTER` na tabela para atualizar |

---

## Problema

Sintomas clássicos:

- a query "ficou lenta do nada", sem mudança de código;
- o plano mostra `Estimated Number of Rows` = 1 e `Actual Number of Rows` = 800.000;
- operadores com aviso de *spill* para `tempdb`;
- `Nested Loops` onde um `Hash Match` seria melhor (ou o contrário);
- concessão de memória muito maior ou muito menor que o necessário;
- piorou depois de uma carga grande, uma migração ou um fechamento de mês.

## Como o SQL Server decide atualizar sozinho

`AUTO_UPDATE_STATISTICS` vem ligado por padrão, mas o gatilho é baseado em volume de
modificações — e em tabelas grandes ele demora a disparar.

O limiar tradicional (comportamento anterior) era, aproximadamente,
**500 + 20% do número de linhas**. Em uma tabela de 100 milhões de linhas, isso significa
esperar **20 milhões de modificações** antes de a estatística ser considerada obsoleta.
Muita coisa acontece antes disso.

A partir do **SQL Server 2016** (com nível de compatibilidade 130 ou superior) passou a
valer, por padrão, um limiar dinâmico, proporcional à raiz quadrada do número de linhas,
que dispara com muito mais frequência em tabelas grandes. Esse comportamento existia
antes sob a trace flag 2371.

**Consequência prática:** em instâncias antigas, ou em bancos mantidos em nível de
compatibilidade baixo por causa de um ERP, a atualização automática pode ser
insuficiente — e uma rotina própria passa a ser necessária.

---

## Diagnóstico

**Rode:** [`verificar-estatisticas-desatualizadas.sql`](verificar-estatisticas-desatualizadas.sql)

A coluna que importa é `modificacoes_pct`: quanto da tabela mudou desde a última
atualização. As demais são contexto.

| Sinal | Leitura |
|---|---|
| `modificacoes_pct` acima de 20% | Estatística provavelmente inútil para estimar |
| `amostragem_pct` muito baixa em tabela grande | A amostra pode não representar a distribuição |
| `ultima_atualizacao` muito antiga em tabela que cresce | Suspeita forte |
| `auto_update_stats = 0` | Alguém desligou. Verifique se existe rotina própria |

### Confirmar no plano

O diagnóstico definitivo é comparar estimado com real:

1. Ative "Include Actual Execution Plan" no SSMS e execute a query.
2. Passe o mouse sobre o operador que lê a tabela.
3. Compare `Estimated Number of Rows` com `Actual Number of Rows`.

Divergência de uma ordem de grandeza ou mais é o problema. Veja
[`como-ler-um-plano-de-execucao.md`](como-ler-um-plano-de-execucao.md).

---

## Correção

### Atualização direcionada (preferível)

```sql
-- Uma tabela específica, varredura completa
UPDATE STATISTICS dbo.<TABELA> WITH FULLSCAN;

-- Uma estatística específica
UPDATE STATISTICS dbo.<TABELA> <NOME_DA_ESTATISTICA> WITH FULLSCAN;

-- Amostragem definida, quando FULLSCAN é caro demais
UPDATE STATISTICS dbo.<TABELA> WITH SAMPLE 30 PERCENT;
```

Direcionar é quase sempre melhor do que atualizar tudo: você paga o I/O de uma tabela em
vez do banco inteiro, e invalida um conjunto pequeno de planos.

### Banco inteiro (com critério)

```sql
EXEC sys.sp_updatestats;
```

Use em janela de manutenção. `sp_updatestats` usa a amostragem padrão, que pode ser
insuficiente em tabelas grandes com distribuição desigual.

### Rotina de manutenção

Estatística deve fazer parte da manutenção regular, junto com índices. Um ponto que gera
muito erro:

| Operação | Atualiza estatísticas? |
|---|---|
| `ALTER INDEX ... REBUILD` | **Sim**, com `FULLSCAN`, como efeito colateral |
| `ALTER INDEX ... REORGANIZE` | **Não.** Nada |

Uma rotina que só faz `REORGANIZE` precisa de um passo separado de `UPDATE STATISTICS`.
É um erro comum e silencioso. Veja
[`../indexes/manutencao-de-indices.md`](../indexes/manutencao-de-indices.md).

Note também que `REBUILD` só atualiza as estatísticas **do índice reconstruído** — as
estatísticas de coluna criadas automaticamente (`_WA_Sys_...`) continuam como estavam.

---

## Quando NÃO atualizar

- **No meio do pico, "para tentar melhorar".** A varredura consome I/O e CPU e costuma
  aprofundar o incidente. Além disso, invalidar planos em massa gera pico de recompilação
  no pior momento.
- **Como reflexo, sem diagnóstico.** Se a divergência entre estimado e real é pequena, a
  estatística não é o problema.
- **Em tabela pequena.** Diferença desprizível.
- **Se o problema real é parameter sniffing.** Atualizar estatística até ajuda (invalida o
  plano ruim), mas o problema volta na próxima compilação. Veja
  [`parameter-sniffing.md`](parameter-sniffing.md).

---

## Casos em que a estatística é insuficiente por natureza

Nem todo erro de estimativa se resolve atualizando.

| Situação | Por que a estimativa erra | Encaminhamento |
|---|---|---|
| Predicado com valor fora do histograma (dado recém-inserido, "ascending key") | O histograma não conhece o valor novo | Atualização mais frequente; avaliar trace flag 2389/2390 em versões antigas; níveis de compatibilidade mais novos já tratam melhor |
| Correlação entre colunas (`Cidade` e `Estado`) | Estatísticas são por coluna; o otimizador multiplica seletividades como se fossem independentes | Estatística multicoluna, ou índice que cubra as duas |
| Variável de tabela | Estimativa fixa de 1 linha (antes do SQL Server 2019) | Trocar por `#tabela`, ou `OPTION (RECOMPILE)` |
| Conversão implícita de tipo | O otimizador não consegue usar o histograma | Corrigir o tipo. Veja [`sargability-e-indices-ignorados.md`](sargability-e-indices-ignorados.md) |
| Função escalar no predicado | Caixa-preta para o otimizador | Reescrever como *inline TVF* ou coluna calculada |

## Mudança de estimador de cardinalidade

O SQL Server 2014 introduziu um novo estimador de cardinalidade (CE). Ele é melhor na
média e **pior em alguns casos específicos** — e o nível de compatibilidade do banco
controla qual estimador é usado.

Um sintoma clássico: "migramos a instância e algumas queries ficaram lentas". Isso
costuma ser mudança de CE, não de hardware nem de estatística.

Se precisar comparar, é possível avaliar o comportamento com o CE legado sem mudar o
banco inteiro, por hint no nível da query ou por configuração de escopo de banco. Trate
como investigação, meça as duas situações e documente a escolha.

## Referências

- [Estatísticas](https://learn.microsoft.com/pt-br/sql/relational-databases/statistics/statistics)
- [`UPDATE STATISTICS`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/update-statistics-transact-sql)
- [`sys.dm_db_stats_properties`](https://learn.microsoft.com/pt-br/sql/relational-databases/system-dynamic-management-views/sys-dm-db-stats-properties-transact-sql)
- [`ALTER DATABASE SCOPED CONFIGURATION`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/alter-database-scoped-configuration-transact-sql)

---

**Criado por Fábio Cerqueira**
