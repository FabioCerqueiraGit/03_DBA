# Templates

> Modelos para expandir o repositório mantendo o mesmo padrão. Quando você resolver um
> problema novo daqui a dois anos, copie o template correspondente, preencha e commite.

| Template | Use para documentar |
|---|---|
| [`template-script-sql.md`](template-script-sql.md) | Script T-SQL de diagnóstico ou manutenção |
| [`template-solucao-csharp.md`](template-solucao-csharp.md) | Padrão ou solução em C#/.NET |
| [`template-troubleshooting.md`](template-troubleshooting.md) | Roteiro de diagnóstico a partir de um sintoma |
| [`template-integracao-api.md`](template-integracao-api.md) | Integração entre sistemas |
| [`template-checklist.md`](template-checklist.md) | Lista de verificação operacional |
| [`template-decisao-arquitetural.md`](template-decisao-arquitetural.md) | Decisão de arquitetura e suas consequências |

## Regras que valem para todos

1. A seção **"Quando NÃO utilizar"** é obrigatória e não pode ser preenchida com
   "sempre pode usar".
2. **Compatibilidade** sempre declarada. Versão mínima de SQL Server, plataforma .NET.
3. **Impacto em produção** sempre declarado, mesmo quando for "nenhum".
4. Documentação em português; código na linguagem original.
5. Nenhum segredo, nome de servidor real ou dado real.
6. Assinatura ao final: `**Criado por Fábio Cerqueira**`.

---

**Criado por Fábio Cerqueira**
