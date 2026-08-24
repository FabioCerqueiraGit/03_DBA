# Arquitetura

> Esta área existe para ajudar a **não** aplicar padrão desnecessário, tanto quanto para aplicar o
> necessário.

---

## Conteúdo

| Documento | Resolve |
|---|---|
| [Quando usar — e quando não usar — cada padrão](quando-usar-cada-padrao.md) | Repository, Unit of Work, Service Layer, CQRS, Mediator, SOLID e Clean Architecture, cada um com o preço que cobra |
| [Consistência entre sistemas: outbox, idempotência e reconciliação](integracao/consistencia-entre-sistemas-outbox-e-reconciliacao.md) | "Gravou aqui e não chegou lá", pedido duplicado no parceiro, compensação quando não dá rollback |

Padrões para código antigo estão em [`sistemas-legados/`](../sistemas-legados/): Strangler Fig,
Anti-Corruption Layer, adapters e modernização incremental.

---

## O critério deste repositório

> **Se, às três da manhã, descobrir qual SQL foi executado exige atravessar quatro camadas, a
> arquitetura está cobrando mais do que entrega.**

Isso não é argumento contra camadas — é argumento contra camadas que não resolvem nada. A
pergunta a fazer antes de adicionar qualquer abstração:

**Qual problema concreto ela resolve neste sistema, hoje?**

Respostas que não contam: "fica mais organizado", "é boa prática", "assim fica preparado para o
futuro". Abstração adicionada antes da necessidade custa leitura todos os dias e paga em um
cenário que talvez nunca ocorra.

---

## Cinco decisões que importam mais que a escolha do padrão

**1. Nenhuma chamada externa dentro de transação aberta.**
HTTP dentro de `BEGIN TRAN` transforma a lentidão do parceiro em bloqueio no seu banco. É uma das
causas mais frequentes de incidente com origem "inexplicável" — ver
[`sql-server/troubleshooting/`](../sql-server/troubleshooting/).

**2. Escrita dupla precisa de outbox.**
Gravar no banco e chamar o parceiro são duas operações sem transação comum. Sem outbox, existem
dois finais ruins e ninguém sabe qual aconteceu.

**3. Todo consumidor precisa ser idempotênte.**
"Exactly-once" não existe. Entrega ao menos uma vez mais processamento idempotente produz o efeito
que se deseja.

**4. Toda integração relevante precisa de reconciliação.**
Nenhum padrão elimina divergência. A rotina que compara os dois lados é o que transforma
divergência silenciosa em alerta.

**5. Mudança de esquema precisa ser retrocompatível.**
Essa é uma decisão arquitetural, mesmo quando parece detalhe de deployment. Ver
[`devops/deployment/`](../devops/deployment/estrategias-de-deployment-e-rollback.md).

---

## Registrar decisões

Decisão arquitetural não registrada vira lenda — e, dois anos depois, alguém "corrige" o que era
deliberação consciente.

O template em [`templates/`](../templates/) cobre o formato: contexto, opções consideradas, decisão,
consequências aceitas. Vale especialmente para as decisões que **não** foram tomadas: "avaliamos
migrar para microsserviços e decidimos manter o monolito porque X" é informação valiosa.

---

**Criado por Fábio Cerqueira**
