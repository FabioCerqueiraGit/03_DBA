# SQL Server — Performance

> Investigação de queries, planos e estatísticas. Se você chegou aqui durante um
> incidente, volte um passo: comece pelo
> [roteiro de diagnóstico](../troubleshooting/sql-server-esta-lento-roteiro-de-diagnostico.md),
> que direciona para o script certo.

---

## Scripts

| Arquivo | Responde à pergunta |
|---|---|
| [`queries-que-mais-consomem-cpu.sql`](queries-que-mais-consomem-cpu.sql) | "Quais queries queimam mais CPU?" — separa *uma query cara* de *milhares de execuções baratas* |
| [`queries-que-mais-fazem-io.sql`](queries-que-mais-fazem-io.sql) | "Quais queries leem mais?" — e quais leem muito para devolver pouco |
| [`queries-mais-lentas-por-duracao.sql`](queries-mais-lentas-por-duracao.sql) | "Quais queries demoram mais?" — separa tempo de CPU de tempo de espera |
| [`verificar-estatisticas-desatualizadas.sql`](verificar-estatisticas-desatualizadas.sql) | "Quais estatísticas estão obsoletas?" |

## Guias

| Documento | Assunto |
|---|---|
| [`como-ler-um-plano-de-execucao.md`](como-ler-um-plano-de-execucao.md) | Roteiro de leitura em cinco passos, e qual número mente |
| [`estatisticas-desatualizadas.md`](estatisticas-desatualizadas.md) | A causa nº 1 de "ficou lento do nada" |
| [`parameter-sniffing.md`](parameter-sniffing.md) | Rápida para um parâmetro, lenta para outro |
| [`sargability-e-indices-ignorados.md`](sargability-e-indices-ignorados.md) | "O índice existe mas o SQL Server não usa" |

---

## Em que ordem investigar

```text
Query lenta
│
├─ 1. Estimado x Real divergem muito?
│      → estatisticas-desatualizadas.md
│
├─ 2. Rápida para uns parâmetros e lenta para outros?
│      → parameter-sniffing.md
│
├─ 3. Plano mostra Scan apesar de existir índice?
│      → sargability-e-indices-ignorados.md
│
├─ 4. Lê muitas páginas para devolver poucas linhas?
│      → ../indexes/encontrar-indices-ausentes.sql
│
└─ 5. Passa mais tempo esperando do que processando?
       → ../monitoramento/waits-em-tempo-real.sql
```

---

## Limitação que vale para todos os scripts desta pasta

`sys.dm_exec_query_stats` enxerga **somente o cache de planos**. Ficam de fora:

- queries com `OPTION (RECOMPILE)`, que nunca entram no cache;
- planos já despejados por pressão de memória;
- tudo, após `DBCC FREEPROCCACHE` ou restart da instância.

Para histórico confíável e para provar regressão de plano, use **Query Store**
(SQL Server 2016+). Ele guarda o histórico por query e por plano, e é a única forma de
responder com evidência a "essa query era rápida semana passada".

---

## Áreas relacionadas

- [`../indexes/`](../indexes/) — índices ausentes, duplicados, não utilizados
- [`../monitoramento/`](../monitoramento/) — o que está acontecendo agora
- [`../troubleshooting/`](../troubleshooting/) — diagnóstico durante incidente

---

**Criado por Fábio Cerqueira**
