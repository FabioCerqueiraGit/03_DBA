# "O índice existe, mas o SQL Server não usa" — SARGability

> O índice está lá, a coluna está na primeira posição, e mesmo assim o plano mostra
> `Scan`. Na maioria das vezes a culpa é do **predicado**, não do índice.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim |
| **Impacto das correções** | Baixo — são reescritas de query |
| **Permissões** | `ALTER` no objeto, para corrigir o código |

---

## Problema

O plano de execução mostra `Index Scan` ou `Clustered Index Scan` onde deveria haver
`Index Seek`, apesar de existir um índice adequado sobre a coluna filtrada.

**SARGable** vem de *Search ARGument able*: um predicado é SARGable quando o SQL Server
consegue usá-lo para navegar na árvore B do índice e ir direto às linhas. Quando não é,
o motor precisa ler tudo e avaliar linha a linha.

A regra que resume quase tudo:

> **Se a coluna indexada estiver "embrulhada" em uma função, conversão ou operação, o
> índice deixa de servir para busca.**

O lado esquerdo da comparação precisa ser a coluna, nua.

---

## Os seis padrões que matam o índice

### 1. Função aplicada sobre a coluna

```sql
-- ❌ Nao SARGable: a funcao esconde a coluna do otimizador
WHERE YEAR(p.DataPedido) = 2026
WHERE MONTH(p.DataPedido) = 3
WHERE CONVERT(DATE, p.DataPedido) = '2026-03-15'

-- ✅ SARGable: intervalo sobre a coluna nua
WHERE p.DataPedido >= '2026-01-01' AND p.DataPedido < '2027-01-01'
WHERE p.DataPedido >= '2026-03-15' AND p.DataPedido < '2026-03-16'
```

O padrão `>= inicio AND < fim_exclusivo` funciona corretamente para `datetime`,
`datetime2`, `date` e `smalldatetime`, e não sofre com a precisão de fração de segundo —
ao contrário de `BETWEEN '2026-03-15' AND '2026-03-15 23:59:59'`, que perde registros
gravados nos últimos milissegundos do dia.

```sql
-- ❌
WHERE UPPER(c.Nome) = 'MARIA'
WHERE LTRIM(RTRIM(c.Documento)) = '12345678900'

-- ✅ colações do SQL Server são, por padrão, case-insensitive:
WHERE c.Nome = 'MARIA'
-- e o espaço em branco deve ser normalizado na GRAVAÇÃO, não na consulta
WHERE c.Documento = '12345678900'
```

### 2. Operação aritmética sobre a coluna

```sql
-- ❌
WHERE i.Preco * 1.1 > 100
WHERE i.Quantidade - i.Reservado > 0

-- ✅ passe a operação para o outro lado
WHERE i.Preco > 100 / 1.1
WHERE i.Quantidade > i.Reservado
```

### 3. `LIKE` começando com curinga

```sql
-- ❌ curinga à esquerda impede a navegação na árvore
WHERE c.Nome LIKE '%silva%'

-- ✅ prefixo permite seek
WHERE c.Nome LIKE 'silva%'
```

Busca por "contém" no meio do texto não é problema de índice B-tree — é caso para
**Full-Text Search**, ou para uma coluna auxiliar com o texto invertido quando a busca é
por sufixo.

### 4. Conversão implícita de tipo

O caso mais insidioso, porque não há nada de errado na aparência da query.

```sql
-- Coluna: Documento VARCHAR(20)
-- Parâmetro chega como NVARCHAR (é o padrão do .NET SqlClient para string!)
WHERE c.Documento = @Documento          -- ❌ vira CONVERT_IMPLICIT no plano
```

Pelas regras de precedência de tipo do SQL Server, `NVARCHAR` tem precedência maior que
`VARCHAR` — então o **lado da coluna** é convertido, e o índice deixa de servir para seek.

Como identificar: no XML do plano aparece `CONVERT_IMPLICIT`, e o plano traz o aviso
*"Type conversion in expression may affect CardinalityEstimate"*.

Correções, em ordem de preferência:

1. **Corrigir o tipo na aplicação.** Em ADO.NET, declare o parâmetro explicitamente:

```csharp
// ❌ AddWithValue infere NVARCHAR para string, causando conversão implícita
command.Parameters.AddWithValue("@Documento", documento);

// ✅ tipo e tamanho explícitos, iguais aos da coluna
command.Parameters.Add("@Documento", SqlDbType.VarChar, 20).Value = documento;
```

Este é, isoladamente, um dos motivos mais fortes para não usar `AddWithValue`. Veja
[`../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md`](../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md).

2. **Padronizar o tipo da coluna** — decisão de modelagem, com migração.

O mesmo vale para comparar `INT` com `VARCHAR`, ou colunas de tipos diferentes em um
`JOIN`: um dos lados será convertido.

### 5. `OR` sobre colunas diferentes

```sql
-- ❌ costuma forçar Scan
WHERE c.Email = @valor OR c.Telefone = @valor

-- ✅ UNION ALL permite um seek por índice
SELECT ... FROM dbo.Cliente WHERE Email = @valor
UNION ALL
SELECT ... FROM dbo.Cliente WHERE Telefone = @valor AND Email <> @valor;
```

O `AND Email <> @valor` no segundo ramo evita duplicidade sem o custo de deduplicação do
`UNION`.

Caso especial muito comum — o filtro opcional:

```sql
-- ❌ o famoso "catch-all"
WHERE (@ClienteId IS NULL OR p.ClienteId = @ClienteId)
  AND (@Status    IS NULL OR p.Status    = @Status)
```

O plano precisa servir a todas as combinações e acaba servindo mal a todas. Duas saídas:

```sql
-- ✅ opção A: recompilar (query de baixa frequência)
... OPTION (RECOMPILE);

-- ✅ opção B: SQL dinâmico PARAMETRIZADO, montando só os filtros informados
```

Se optar por SQL dinâmico, use `sp_executesql` com parâmetros — **nunca** concatene
valores. Veja [`../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md`](../../acesso-a-dados/ado-net/ado-net-fundamentos-seguros.md).

### 6. Função escalar de usuário no predicado

```sql
-- ❌ função escalar no WHERE
WHERE dbo.fn_CalcularSaldo(c.ClienteId) > 1000
```

Além de impedir o seek, uma UDF escalar executa **uma vez por linha** e, em versões
anteriores ao SQL Server 2019, impede o paralelismo do plano inteiro.

**Correção:** transformar em *inline table-valued function* e usar `CROSS APPLY`, ou
materializar o valor em coluna calculada persistida e indexada.

O SQL Server 2019 introduziu *Scalar UDF Inlining*, que converte automaticamente muitas
UDFs escalares em expressões — mas nem toda função se qualifica, e o recurso depende do
nível de compatibilidade do banco. **Não conte com isso**; corrija o código.

---

## Como confirmar no plano

| Sinal no plano | Significado |
|---|---|
| `Index Scan` / `Clustered Index Scan` onde deveria haver `Seek` | Predicado provavelmente não SARGable |
| `CONVERT_IMPLICIT` no `Predicate` | Conversão de tipo — corrija o tipo do parâmetro |
| Aviso *Type conversion in expression may affect CardinalityEstimate* | Idem |
| Filtro aparece em `Predicate` e não em `Seek Predicates` | O índice foi usado para varrer, não para buscar |

A distinção entre `Seek Predicates` e `Predicate` é a mais útil de todas: o primeiro é o
que navega na árvore; o segundo é o que filtra depois de ler. Um índice cujo filtro caiu
em `Predicate` está sendo lido inteiro.

---

## Quando o `Scan` é a escolha certa

Nem todo `Scan` é erro. O otimizador escolhe varrer, corretamente, quando:

- a query retorna uma fração grande da tabela — a partir de um certo percentual, varrer
  sai mais barato que fazer muitos lookups;
- a tabela é pequena (poucas páginas), e o seek não compensa;
- o índice não é *covering* e o número de lookups estimado é alto demais.

Nesses casos, o caminho é **cobrir o índice** com `INCLUDE`, ou reduzir o volume
retornado — não brigar com o otimizador.

## Como NÃO corrigir

| Antipadrão | Por que é ruim |
|---|---|
| `WITH (INDEX(...))` para forçar o índice | Trata o sintoma, engessa o plano e quebra quando o índice for renomeado ou o volume mudar |
| `WITH (FORCESEEK)` | Idem. Pode piorar muito se o seek de fato não for o melhor caminho |
| Criar mais um índice para cada query lenta | Cada índice penaliza toda escrita e ocupa espaço. Corrija o predicado primeiro |

Dicas de índice são ferramenta de emergência com prazo de validade. Se usar, **comente no
código** o motivo e a data.

## Referências

- [Guia de arquitetura de processamento de consultas](https://learn.microsoft.com/pt-br/sql/relational-databases/query-processing-architecture-guide)
- [Precedência de tipos de dados](https://learn.microsoft.com/pt-br/sql/t-sql/data-types/data-type-precedence-transact-sql)
- [Guia de design de índices](https://learn.microsoft.com/pt-br/sql/relational-databases/sql-server-index-design-guide)

---

**Criado por Fábio Cerqueira**
