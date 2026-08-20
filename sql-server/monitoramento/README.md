# SQL Server — Monitoramento

> O que está acontecendo na instância **agora**. Diferente de
> [`../troubleshooting/`](../troubleshooting/), que é para incidente, esta área serve
> tanto para investigação quanto para acompanhamento em regime normal.

---

## Scripts

| Arquivo | Responde à pergunta |
|---|---|
| [`sessoes-e-requests-em-execucao.sql`](sessoes-e-requests-em-execucao.sql) | "Quem está conectado, o que está rodando, quem está ocioso com transação aberta e qual aplicação abre mais conexões?" |
| [`waits-em-tempo-real.sql`](waits-em-tempo-real.sql) | "O que as sessões estão esperando **neste momento**?" |
| [`analisar-waits-acumulados.sql`](analisar-waits-acumulados.sql) | "Em que a instância gastou tempo esperando desde o restart?" |
| [`memory-grants-e-fila-de-memoria.sql`](memory-grants-e-fila-de-memoria.sql) | "Há fila por memória? Quem pediu muito mais do que usou?" |
| [`espaco-em-disco-e-arquivos-do-banco.sql`](espaco-em-disco-e-arquivos-do-banco.sql) | "Quanto espaço resta? Qual a latência real de I/O por arquivo?" |

---

## Tempo real ou acumulado?

A escolha entre as duas visões de espera é o erro mais comum desta área.

| | Tempo real | Acumulado |
|---|---|---|
| **Script** | `waits-em-tempo-real.sql` | `analisar-waits-acumulados.sql` |
| **Fonte** | `sys.dm_os_waiting_tasks` | `sys.dm_os_wait_stats` |
| **Mostra** | O que está esperando agora | O que esperou desde o restart |
| **Use durante incidente** | **Sim** | Não — dilui o incidente em semanas de operação normal |
| **Use para tendência** | Não | Sim |
| **Zera quando** | É instantâneo | No restart da instância ou com `DBCC SQLPERF(...)` |

---

## O ajuste de observabilidade mais barato que existe

Se todas as conexões chegam como `.Net SqlClient Data Provider`, nenhum diagnóstico
consegue apontar **qual** sistema causou o problema. Configure `Application Name` na
connection string de cada aplicação:

```text
Server=<SERVIDOR>;Database=<BANCO>;...;Application Name=<NOME-DO-SISTEMA>
```

Custa uma linha de configuração e transforma toda investigação futura. A partir daí,
`program_name` nas DMVs passa a responder "de quem é essa query".

---

## Áreas relacionadas

- [`../troubleshooting/`](../troubleshooting/) — diagnóstico durante incidente
- [`../performance/`](../performance/) — investigação de queries e planos
- [`../espaco-e-crescimento/`](../espaco-e-crescimento/) — tamanho de tabelas e índices

---

**Criado por Fábio Cerqueira**
