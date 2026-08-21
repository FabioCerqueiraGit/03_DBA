# Checklists

> Listas de verificação operacionais. Servem para o momento em que a memória falha: antes
> de um deploy, ao assumir uma instância, durante a revisão trimestral.

| Checklist | Quando aplicar |
|---|---|
| [`checklist-producao-sql-server.md`](checklist-producao-sql-server.md) | Ao assumir uma instância SQL Server; depois, trimestralmente |
| [`checklist-deployment-aplicacao-dotnet.md`](checklist-deployment-aplicacao-dotnet.md) | Antes de cada deploy em produção |

Para criar novos: [`../templates/template-checklist.md`](../templates/template-checklist.md).

---

## Como escrever um item de checklist que funciona

| Ruim | Bom |
|---|---|
| "Verificar backup" | "Backup full com menos de 24h **e** restore testado nos últimos 90 dias" |
| "Conferir performance" | "Latência p95 abaixo de 300 ms na tela de consulta de pedidos" |
| "Ver se está seguro" | "Nenhuma aplicação conectando como `sa`" |

A regra: **a resposta precisa ser objetivamente sim ou não.** Item que admite "mais ou
menos" é item que sempre passa.

---

**Criado por Fábio Cerqueira**
