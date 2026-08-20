# Como ler um plano de execução sem se perder

> Um plano de execução tem dezenas de operadores e centenas de propriedades. Você não
> precisa entender todos. Precisa saber **onde olhar primeiro** e **qual número mente**.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim |
| **Impacto** | Nenhum para plano estimado; para plano real, o custo é o da própria query |
| **Permissões** | `SHOWPLAN` no banco |

---

## Plano estimado ou plano real?

| | Estimado | Real |
|---|---|---|
| **Como obter (SSMS)** | <kbd>Ctrl</kbd>+<kbd>L</kbd> | <kbd>Ctrl</kbd>+<kbd>M</kbd>, depois executar |
| **Executa a query?** | Não | Sim |
| **Mostra linhas reais** | Não | **Sim** |
| **Mostra spills e avisos de execução** | Parcialmente | Sim |
| **Use para** | Query cara ou destrutiva que você não quer executar | **Praticamente todo diagnóstico** |

O plano **real** é o que resolve problemas, porque é ele que permite comparar
`Estimated Number of Rows` com `Actual Number of Rows`. Essa comparação é o coração de
quase toda investigação.

Para pegar o plano de algo que já rodou, sem executar de novo, use a coluna `plano` dos
scripts de [`queries-que-mais-consomem-cpu.sql`](queries-que-mais-consomem-cpu.sql) e
similares — ou o Query Store.

---

## A ordem em que se lê

O desenho no SSMS é lido **da direita para a esquerda e de cima para baixo**. Os dados
entram pela direita (leitura das tabelas) e fluem para a esquerda até o `SELECT`.

A espessura das setas representa o **número de linhas** trafegando. Seta grossa que fica
fina logo adiante significa que muita linha foi lida para pouca ser aproveitada — quase
sempre há um índice ou um predicado a corrigir ali.

---

## Roteiro de leitura em cinco passos

### Passo 1 — Procure avisos (o triângulo amarelo)

Antes de qualquer coisa, procure operadores com sinal de aviso. Eles apontam o problema
sem esforço:

| Aviso | Significado | Encaminhamento |
|---|---|---|
| *Type conversion in expression may affect CardinalityEstimate* | Conversão implícita de tipo | [`sargability-e-indices-ignorados.md`](sargability-e-indices-ignorados.md) |
| *Operator used tempdb to spill data* | A memória concedida não bastou | Estimativa ruim → [`estatisticas-desatualizadas.md`](estatisticas-desatualizadas.md) |
| *No Join Predicate* | Junção sem condição — produto cartesiano | Erro na query |
| *Columns With No Statistics* | Faltam estatísticas para uma coluna do predicado | Criar estatística ou índice |
| *Excessive Grant* | Concessão de memória muito acima do uso | Estimativa ruim |

### Passo 2 — Compare estimado com real

Passe o mouse sobre o operador mais à direita (o que lê a tabela) e compare:

```text
Estimated Number of Rows ......  1
Actual Number of Rows ......... 842.317
```

Divergência de uma ordem de grandeza ou mais é o achado. Causas, em ordem:

1. estatística desatualizada;
2. parameter sniffing;
3. conversão implícita de tipo;
4. variável de tabela (estimativa fixa de 1 linha em versões anteriores ao SQL Server 2019);
5. função escalar no predicado;
6. correlação entre colunas que o otimizador trata como independentes.

Em plano com paralelismo, atenção: dependendo da versão e do modo de exibição, o número
estimado pode ser **por thread** enquanto o real é o total — confira o grau de
paralelismo antes de concluir que a estimativa errou.

### Passo 3 — Localize o operador mais caro

O `Cost %` de cada operador ajuda a focar. Mas cuidado com a armadilha:

> **O custo exibido é sempre uma ESTIMATIVA, inclusive no plano "real".**

O SQL Server não mede o custo real; ele mostra o custo que o otimizador calculou. Se a
estimativa estava errada (Passo 2), o custo também está — e é comum ver o operador
realmente problemático marcado com "0%".

Por isso: **use `Cost %` como pista, e o número de linhas como evidência.**

### Passo 4 — Identifique os operadores caros por natureza

| Operador | O que significa | Quando preocupa |
|---|---|---|
| `Clustered Index Scan` / `Table Scan` | Leu a tabela inteira | Quando a query devolve poucas linhas |
| `Index Scan` | Leu o índice inteiro | Idem |
| `Index Seek` | Navegou direto — em geral, o que se quer | Raramente preocupa |
| `Key Lookup` / `RID Lookup` | Voltou à tabela para buscar colunas fora do índice | Quando o número de execuções é alto — resolve-se com `INCLUDE` |
| `Sort` | Ordenação | Sempre caro; pode ser evitado por índice na ordem certa |
| `Hash Match` | Junção ou agregação por hash | Normal em volume grande; suspeito em volume pequeno (indica estimativa alta demais) |
| `Nested Loops` | Laço | Ótimo para poucas linhas; catastrófico para muitas |
| `Table Spool` / `Index Spool` | Materialização temporária no `tempdb` | Frequentemente indica falta de índice |
| `Parallelism (Gather Streams)` | Junção de threads paralelas | Normal; avalie se a query merecia paralelismo |
| `Filter` | Filtro aplicado **depois** de ler | Se pudesse ser aplicado na leitura, seria melhor |
| `Compute Scalar` | Cálculo de expressão | Barato, exceto se envolver UDF escalar |

### Passo 5 — Leia `Seek Predicates` versus `Predicate`

Esta é a distinção mais útil e a menos conhecida. Nas propriedades de um operador de
índice:

- **`Seek Predicates`** — o que foi usado para **navegar** na árvore do índice. É o filtro
  eficiente.
- **`Predicate`** — o que foi aplicado **depois de ler** as linhas. É filtro residual.

Um `Index Seek` cujo filtro principal aparece em `Predicate`, e não em `Seek Predicates`,
está lendo muito mais do que precisa. Corrigir isso costuma ser questão de **ordem das
colunas** no índice, não de criar um índice novo.

---

## `SET STATISTICS IO` e `SET STATISTICS TIME`

Quando quiser números em vez de desenho:

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- sua query aqui

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

Na aba **Messages**:

```text
Table 'Pedido'. Scan count 1, logical reads 481.203, physical reads 12, ...

SQL Server Execution Times:
   CPU time = 3.187 ms,  elapsed time = 3.402 ms.
```

Leitura:

- **`logical reads`** é o número mais honesto para comparar duas versões da mesma query.
  Diferente do tempo, não varia com a carga da máquina nem com o que já está em cache.
- **`physical reads`** cai para zero na segunda execução, quando os dados já estão em
  memória — não use para comparar.
- **`CPU time` muito abaixo de `elapsed time`** significa espera: I/O, bloqueio ou rede.

Para comparar duas versões de uma query, use `logical reads` como métrica primária.

---

## Erros comuns de interpretação

| Erro | Por quê |
|---|---|
| "O custo é 87%, o problema é esse operador" | O custo é estimado. Se a estimativa errou, o custo mente |
| "Tem `Scan`, logo está errado" | `Scan` é a escolha certa quando a query devolve boa parte da tabela ou a tabela é pequena |
| "Vou forçar o índice com hint" | Trata o sintoma e engessa o plano. Corrija o predicado ou o índice |
| "O plano estimado basta" | Sem linhas reais, o diagnóstico principal fica indisponível |
| "A query demora 3 s, então o banco está lento" | Compare `CPU time` com `elapsed time` antes de concluir |

## Ferramentas

- **SSMS** — visualização nativa. Salve o plano como `.sqlplan` para analisar depois ou
  anexar a um chamado.
- **Query Store** (SQL Server 2016+) — o histórico de planos por query. É a única forma
  confíável de provar uma regressão de plano.
- **Plan Explorer** (SentryOne/SolarWinds) — visualização alternativa gratuita, com
  destaque melhor para divergência entre estimado e real.

## Referências

- [Planos de execução](https://learn.microsoft.com/pt-br/sql/relational-databases/performance/execution-plans)
- [Exibir e salvar planos de execução](https://learn.microsoft.com/pt-br/sql/relational-databases/performance/display-and-save-execution-plans)
- [Referência de operadores de plano de execução](https://learn.microsoft.com/pt-br/sql/relational-databases/showplan-logical-and-physical-operators-reference)
- [`SET STATISTICS IO`](https://learn.microsoft.com/pt-br/sql/t-sql/statements/set-statistics-io-transact-sql)

---

**Criado por Fábio Cerqueira**
