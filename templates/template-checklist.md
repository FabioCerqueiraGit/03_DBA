# Checklist — [contexto]

> Quando usar esta lista e quem é responsável por ela.

| | |
|---|---|
| **Quando aplicar** | Antes de cada deploy / mensalmente / durante incidente |
| **Responsável** | Papel, não pessoa |
| **Tempo estimado** | |

---

## Antes

- [ ] Item verificável. Escreva de forma que a resposta seja objetivamente sim ou não.
- [ ] Item com critério explícito: "backup full com menos de 24h **e** restore testado".

## Durante

- [ ] 

## Depois

- [ ] 

## Critérios de rollback

Defina **antes**, não durante. Sob pressão ninguém decide bem.

| Gatilho | Ação |
|---|---|
| Taxa de erro acima de X% por Y minutos | Rollback imediato |
| Latência p95 acima de X ms | Avaliar em N minutos |

## Se algo der errado

Ordem das ações, quem avisar, o que preservar antes de mexer.

---

**Criado por Fábio Cerqueira**
