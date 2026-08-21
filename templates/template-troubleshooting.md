# [Sintoma como ele é relatado, entre aspas]

> Exemplo: "O sistema está lento desde as 14h". O título é o que a pessoa digita na busca,
> não o nome técnico da causa.

| | |
|---|---|
| **Sintoma** | Como o problema é relatado |
| **Escopo** | Aplicação / Banco / Rede / Infraestrutura |
| **Urgência típica** | Incidente em produção / Investigação |

---

## Antes de qualquer coisa

Três perguntas que economizam meia hora:

1. **Mudou alguma coisa?** Deploy, patch, job, volume, nova integração.
2. **É todo mundo ou só um?** Um usuário, uma tela, um cliente, ou o sistema inteiro.
3. **Quando começou exatamente?** Correlacione com o item 1.

## Roteiro de diagnóstico

### Passo 1 — [Pergunta que este passo responde]

**O que rodar:**

```sql
-- ou C#, ou comando de shell
```

**Como interpretar:**

| Resultado | Significa | Vá para |
|---|---|---|
| A | | Passo 2 |
| B | | Passo 5 |

### Passo 2 — ...

## Árvore de decisão

```text
Sintoma
|-- Evidencia A  ->  Causa provavel 1  ->  <caminho-do-documento>.md
|-- Evidencia B  ->  Causa provavel 2  ->  <caminho-do-documento>.md
`-- Nenhuma      ->  Passo seguinte
```

## Causas mais comuns, em ordem de frequência

Liste por frequência real, não por sofisticação técnica. A causa chata e óbvia é a mais
provável às três da manhã.

| # | Causa | Como confirmar | Solução |
|---|---|---|---|

## Mitigação imediata versus correção definitiva

| | Mitigação | Correção |
|---|---|---|
| O que faz | Para a dor agora | Resolve a origem |
| Risco | | |
| Quando escolher | | |

Seja explícito sobre o custo da mitigação. Matar a sessão bloqueadora resolve o minuto
seguinte e não resolve a causa — e pode gerar rollback longo.

## O que NÃO fazer

Ações que pioram a situação e que costumam ser tentadas sob pressão.

## O que registrar antes de mexer

Evidência que desaparece quando o problema é mitigado. Se você matar a sessão sem salvar a
saída, perdeu a investigação.

## Referências

---

**Criado por Fábio Cerqueira**
