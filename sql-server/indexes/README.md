# SQL Server — Índices

> Índice é a ferramenta mais poderosa e mais mal usada do SQL Server. Um índice certo
> transforma uma query de 40 segundos em 40 milissegundos. Dez índices errados na mesma
> tabela transformam cada `INSERT` em dez trabalhos extras.

---

## Scripts

| Arquivo | Responde à pergunta |
|---|---|
| [`encontrar-indices-ausentes.sql`](encontrar-indices-ausentes.sql) | "Quais índices o otimizador gostaria de ter?" — com o alerta sobre por que **não** aplicar tudo |
| [`encontrar-indices-nao-utilizados.sql`](encontrar-indices-nao-utilizados.sql) | "Quais índices só custam escrita e nunca servem leitura?" |
| [`encontrar-indices-duplicados-e-redundantes.sql`](encontrar-indices-duplicados-e-redundantes.sql) | "Quais índices são cópia ou subconjunto de outros?" |
| [`analisar-fragmentacao.sql`](analisar-fragmentacao.sql) | "Quais índices estão fragmentados o suficiente para justificar manutenção?" |

## Guias

| Documento | Assunto |
|---|---|
| [`manutencao-de-indices.md`](manutencao-de-indices.md) | `REBUILD` versus `REORGANIZE`, quando cada um, e o erro silencioso das rotinas de manutenção |

---

## A ordem correta de trabalho

A tentação é começar criando índices. A ordem que dá resultado é outra:

```text
1. REMOVER o que não serve
   ├─ indices duplicados      → encontrar-indices-duplicados-e-redundantes.sql
   └─ indices não utilizados  → encontrar-indices-nao-utilizados.sql

2. CORRIGIR o que impede o uso dos existentes
   └─ predicados não SARGable → ../performance/sargability-e-indices-ignorados.md

3. SOMENTE ENTÃO criar o que falta
   └─ com análise            → encontrar-indices-ausentes.sql
```

Por quê: em muitos bancos maduros, remover índices redundantes melhora a escrita
imediatamente e não custa nada em leitura. E um predicado não SARGable faz o índice novo
ser ignorado exatamente como o antigo — você paga o custo e não colhe o benefício.

---

## O custo real de um índice

Cada índice não clusterizado cobra em quatro lugares:

| Custo | Detalhe |
|---|---|
| **Escrita** | Todo `INSERT`, `UPDATE` e `DELETE` que toque as colunas do índice precisa mantê-lo |
| **Espaço** | Em disco, em backup e no buffer pool — disputando memória com os dados |
| **Manutenção** | Reconstrução, reorganização e estatísticas |
| **Otimização** | Mais opções a avaliar em cada compilação de plano |

Por isso a pergunta nunca é "esse índice ajuda alguma query?", e sim **"o ganho na leitura
compensa o custo na escrita?"**.

---

## A limitação que vale para todos os scripts desta pasta

As DMVs de uso de índice (`sys.dm_db_index_usage_stats`,
`sys.dm_db_missing_index_*`) **zeram no restart da instância**, e podem ser afetadas por
outras operações administrativas. Consequências práticas:

- **Não conclua nada com uptime baixo.** Cada script mostra o uptime justamente por isso.
- **Considere o ciclo de negócio.** Um índice que parece inútil pode servir ao fechamento
  mensal, ao balanço anual ou a um relatório trimestral. Uptime de duas semanas não
  enxerga isso.

---

## Áreas relacionadas

- [`../performance/`](../performance/) — por que um índice existente não é usado
- [`../espaco-e-crescimento/`](../espaco-e-crescimento/) — quanto espaço os índices ocupam
- [`../troubleshooting/`](../troubleshooting/) — diagnóstico durante incidente

---

**Criado por Fábio Cerqueira**
