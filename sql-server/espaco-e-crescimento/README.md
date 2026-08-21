# SQL Server — Espaço e crescimento

> "Por que o banco está crescendo?" É uma pergunta de capacidade, e ela se responde com
> números, não com intuição.

---

## Scripts

| Arquivo | Responde à pergunta |
|---|---|
| [`tamanho-das-tabelas.sql`](tamanho-das-tabelas.sql) | "Quais tabelas ocupam mais espaço? Quanto é dado e quanto é índice?" |
| [`tamanho-dos-indices.sql`](tamanho-dos-indices.sql) | "Quanto cada índice ocupa, com quais colunas, e ele é lido?" |

Para espaço em disco, tamanho de arquivo e latência de I/O, veja
[`../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql`](../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql).

---

## O erro de leitura mais comum

**Espaço reservado e não usado não é desperdício.** Uma tabela que teve um `DELETE` massivo
mantém as páginas alocadas — e isso está certo: elas serão reaproveitadas na próxima
inserção, sem custo de alocação.

Ver esse número alto **não é motivo para `SHRINK`**. Veja
[`../administracao/shrink-quando-nao-usar.md`](../administracao/shrink-quando-nao-usar.md).

---

## Sem histórico não há resposta

A primeira pergunta de qualquer incidente de crescimento é "desde quando?". Nenhuma DMV
responde isso: elas mostram o estado atual, não a série temporal.

Colete [`tamanho-das-tabelas.sql`](tamanho-das-tabelas.sql) periodicamente e guarde o
resultado em uma tabela própria, com data. Uma coleta diária em um job simples transforma
"acho que começou mês passado" em um gráfico — e um gráfico encerra a discussão em uma
reunião de capacidade.

---

## Antes de pedir mais disco

| Verifique | Onde |
|---|---|
| Os índices ocupam mais que os dados? | [`tamanho-dos-indices.sql`](tamanho-dos-indices.sql) |
| Há índices duplicados ou não utilizados? | [`../indexes/`](../indexes/) |
| O transaction log está crescendo por falta de backup? | [`../troubleshooting/por-que-o-transaction-log-esta-crescendo.md`](../troubleshooting/por-que-o-transaction-log-esta-crescendo.md) |
| Há backups antigos ocupando o volume? | [`../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql`](../monitoramento/espaco-em-disco-e-arquivos-do-banco.sql) |
| Tabela histórica poderia ser comprimida ou arquivada? | [`../administracao/shrink-quando-nao-usar.md`](../administracao/shrink-quando-nao-usar.md) |

---

**Criado por Fábio Cerqueira**
