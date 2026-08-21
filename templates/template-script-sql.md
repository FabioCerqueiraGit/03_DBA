# [Título: o problema que o script resolve, não o nome da DMV]

> Uma linha explicando o que este script responde.

| | |
|---|---|
| **Arquivo** | `nome-do-script.sql` |
| **Compatibilidade** | SQL Server 20XX+ (XX.x) · Azure SQL Database: sim/não/parcial |
| **Impacto em produção** | Nenhum (somente leitura) / Baixo / Alto — exige janela |
| **Permissões** | `VIEW SERVER STATE` / `db_datareader` / `sysadmin` |
| **Tempo estimado** | < X segundos |

---

## Problema

Que pergunta de produção este script responde. Escreva como a pergunta chegaria até você:
*"por que a gravação de pedido está travando desde as 9h?"*, não *"consulta à
`sys.dm_tran_locks`"*.

## Quando utilizar

- Situação concreta 1.
- Situação concreta 2.

## Quando NÃO utilizar

- Situação em que o resultado engana. **Obrigatório.**
- Situação em que existe ferramenta melhor — aponte qual.

## Pré-requisitos

- Permissão necessária e como conceder com o mínimo de privilégio.
- Estado necessário da instância (uptime mínimo, Query Store ativo, etc.).

## Script

```sql
/* ===========================================================================
   NOME       : nome-do-script.sql
   OBJETIVO   : ...

   COMPATIBILIDADE : SQL Server 20XX+ (XX.x).
   IMPACTO         : Nenhum. Somente leitura sobre DMVs.
   PERMISSOES      : VIEW SERVER STATE.
   TEMPO ESTIMADO  : < X segundos.

   ATENCAO    : Limitacoes conhecidas do resultado.

   AUTOR      : Fabio Cerqueira
   =========================================================================== */
```

## Como utilizar

Onde executar (contexto de banco ou de instância), o que ajustar antes de rodar, como
ordenar o resultado.

## Explicação

O que cada coluna do resultado significa e — mais importante — **o que fazer com ela**.
Uma coluna que você não sabe interpretar não deveria estar no `SELECT`.

## Exemplo

Saída anotada, com valores fictícios, mostrando como se lê o resultado.

## Cuidados

Onde este script mente. DMVs zeram no restart; `avg_user_impact` é uma estimativa do
otimizador, não uma medição; fragmentação em tabela pequena é ruído.

## Performance

Custo de execução do próprio script. Se ele pode causar bloqueio ou I/O relevante, diga
aqui — e diga como reduzir.

## Segurança

Se a saída pode expor dado de negócio (texto de query com literais, nome de objeto),
avise. Trate a saída como log de produção.

## Compatibilidade

O que muda por versão. Alternativa para versões anteriores, quando existir.

## Troubleshooting

| Erro | Causa provável | Correção |
|---|---|---|
| `The user does not have permission to perform this action.` | Falta `VIEW SERVER STATE` | `GRANT VIEW SERVER STATE TO [<LOGIN>];` |

## Referências

- [Documentação oficial](https://learn.microsoft.com/pt-br/sql/)

---

**Criado por Fábio Cerqueira**
