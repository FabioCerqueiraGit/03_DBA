# SQL Server — Troubleshooting

> O que você abre **durante** um incidente. Se você chegou aqui com o sistema fora do ar,
> comece pelo roteiro de diagnóstico: ele direciona para o arquivo certo em poucos passos.

---

## Comece aqui

**[→ "O SQL Server está lento" — roteiro de diagnóstico](sql-server-esta-lento-roteiro-de-diagnostico.md)**

Oito passos que separam bloqueio de query ruim de problema de infraestrutura, com árvore
de decisão e a lista do que **não** fazer sob pressão.

---

## Scripts de diagnóstico

Todos são somente leitura e seguros para produção.

| Arquivo | Responde à pergunta |
|---|---|
| [`diagnostico-rapido-30-segundos.sql`](diagnostico-rapido-30-segundos.sql) | "O que está acontecendo agora?" — triagem geral em uma execução |
| [`quem-esta-bloqueando-quem.sql`](quem-esta-bloqueando-quem.sql) | "Quem está bloqueando quem?" — com o texto da query do bloqueador |
| [`arvore-de-bloqueio-hierarquica.sql`](arvore-de-bloqueio-hierarquica.sql) | "Qual é a sessão RAIZ da cadeia de bloqueio?" |
| [`encontrar-transacoes-abertas-longa-duracao.sql`](encontrar-transacoes-abertas-longa-duracao.sql) | "Existe transação aberta há muito tempo?" |
| [`extrair-deadlocks-do-system-health.sql`](extrair-deadlocks-do-system-health.sql) | "Tivemos deadlock? Quando? Entre o quê?" |
| [`diagnosticar-crescimento-transaction-log.sql`](diagnosticar-crescimento-transaction-log.sql) | "Por que o transaction log não para de crescer?" |
| [`analisar-uso-do-tempdb.sql`](analisar-uso-do-tempdb.sql) | "Quem está consumindo o tempdb?" |

## Guias de diagnóstico

| Documento | Assunto |
|---|---|
| [`sql-server-esta-lento-roteiro-de-diagnostico.md`](sql-server-esta-lento-roteiro-de-diagnostico.md) | Roteiro âncora de lentidão |
| [`investigar-deadlocks.md`](investigar-deadlocks.md) | Ler o grafo, identificar o padrão, corrigir a causa, tratar com retry |
| [`por-que-o-transaction-log-esta-crescendo.md`](por-que-o-transaction-log-esta-crescendo.md) | `log_reuse_wait_desc` e por que trocar para `SIMPLE` é perigoso |
| [`diagnosticar-tempdb.md`](diagnosticar-tempdb.md) | Version store, objetos internos, objetos de usuário e contenção de alocação |
| [`matar-sessao-com-seguranca.md`](matar-sessao-com-seguranca.md) | Checklist antes de `KILL`, e quando **não** matar |

---

## Regra de ouro do incidente

**Salve a evidência antes de mitigar.** A cadeia de bloqueio, a transação aberta e a
sessão bloqueadora desaparecem no instante em que você age. Sem a saída dos scripts
salva em arquivo, a reunião de pós-incidente termina em "matamos a sessão e melhorou" —
o que garante a reincidência.

---

## Áreas relacionadas

- [`../monitoramento/`](../monitoramento/) — o que está acontecendo agora, em regime normal
- [`../performance/`](../performance/) — investigação de queries, planos e estatísticas
- [`../indexes/`](../indexes/) — índices ausentes, duplicados, não utilizados
- [`../administracao/`](../administracao/) — backup, restore, DBCC, permissões
- [`../../INDICE-POR-SINTOMA.md`](../../INDICE-POR-SINTOMA.md) — navegação por sintoma

---

**Criado por Fábio Cerqueira**
