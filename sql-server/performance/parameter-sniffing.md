# Parameter sniffing — a mesma query, rápida para um parâmetro e lenta para outro

> "A procedure roda em 200 ms para o cliente A e em 4 minutos para o cliente B — e o
> código é o mesmo." Este é o retrato do parameter sniffing.

| | |
|---|---|
| **Compatibilidade** | SQL Server 2012+ (11.x) · Azure SQL Database: sim |
| **Impacto das correções** | Varia de baixo (`OPTIMIZE FOR`) a alto (forçar plano) |
| **Permissões** | `ALTER` no objeto para alterar a procedure |

---

## Problema

Sintomas típicos:

- a mesma procedure é rápida para uns parâmetros e lenta para outros;
- `min_elapsed_time` e `max_elapsed_time` da mesma entrada em
  `sys.dm_exec_query_stats` diferem por ordens de grandeza (o script
  [`queries-mais-lentas-por-duracao.sql`](queries-mais-lentas-por-duracao.sql) sinaliza
  isso na coluna `variacao`);
- "ficou lento depois do restart" ou "depois que atualizamos as estatísticas";
- executar a mesma procedure com `WITH RECOMPILE` resolve — e essa é a confirmação
  diagnóstica mais direta.

## O que é, de fato

Parameter sniffing **é uma otimização**, não um defeito. Na primeira execução, o SQL
Server "fareja" (*sniff*) o valor do parâmetro, estima a cardinalidade com base nele,
gera o plano ideal para aquele valor e **guarda esse plano no cache**. As execuções
seguintes reaproveitam o plano — o que economiza compilação e é o comportamento desejado
na esmagadora maioria dos casos.

O problema aparece quando a **distribuição dos dados é muito desigual**:

```sql
CREATE PROCEDURE dbo.usp_PedidosPorCliente
    @ClienteId INT
AS
SELECT p.PedidoId, p.Data, p.Valor
FROM dbo.Pedido AS p
WHERE p.ClienteId = @ClienteId;
```

- Cliente 4711 tem **3 pedidos** → o plano ideal é `Index Seek` + `Key Lookup`.
- Cliente 1 (a rede de lojas) tem **4 milhões de pedidos** → o plano ideal é
  `Clustered Index Scan`.

Se o plano foi compilado para o cliente 4711 e depois é usado para o cliente 1, o SQL
Server executa 4 milhões de lookups. Se foi compilado para o cliente 1, todas as consultas
pequenas passam a varrer a tabela inteira.

**Por isso "reiniciou e ficou lento" faz sentido:** o cache esvaziou e a primeira execução
depois do restart, por acaso, foi a atípica.

---

## Como confirmar

### 1. Comparar mínimo e máximo

```sql
SELECT
    execucoes         = qs.execution_count,
    duracao_media_ms  = qs.total_elapsed_time / 1000.0 / qs.execution_count,
    duracao_minima_ms = qs.min_elapsed_time / 1000.0,
    duracao_maxima_ms = qs.max_elapsed_time / 1000.0,
    proporcao         = qs.max_elapsed_time * 1.0 / NULLIF(qs.min_elapsed_time, 0),
    objeto            = OBJECT_NAME(t.objectid, t.dbid),
    comando           = t.text
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
WHERE qs.execution_count > 10
  AND qs.min_elapsed_time > 0
  AND qs.max_elapsed_time / NULLIF(qs.min_elapsed_time, 0) > 100
ORDER BY proporcao DESC;
```

Proporção alta entre máximo e mínimo, com o mesmo plano, é forte indício.

### 2. Comparar estimado com real no plano

No plano de execução **real**, compare `Estimated Number of Rows` com
`Actual Number of Rows` no operador que lê a tabela. Divergência de ordens de grandeza,
combinada com plano em cache, confirma o diagnóstico.

Ver [`como-ler-um-plano-de-execucao.md`](como-ler-um-plano-de-execucao.md).

### 3. Descobrir com qual valor o plano foi compilado

O XML do plano guarda o valor farejado:

```sql
SELECT
    valor_compilado = pa.value,
    parametro       = pa.name
FROM sys.dm_exec_cached_plans AS cp
CROSS APPLY sys.dm_exec_query_plan(cp.plan_handle) AS qp
CROSS APPLY qp.query_plan.nodes('//ParameterList/ColumnReference') AS n(c)
CROSS APPLY (SELECT name  = n.c.value('@Column', 'NVARCHAR(128)'),
                    value = n.c.value('@ParameterCompiledValue', 'NVARCHAR(256)')) AS pa
WHERE qp.query_plan IS NOT NULL
  AND pa.value IS NOT NULL;
```

Ajuste o filtro para o objeto de interesse; sem filtro, esta consulta percorre o cache
inteiro e pode ser pesada em instâncias grandes.

---

## Soluções, da menos invasiva para a mais

Não existe correção universal. Escolha pelo padrão de uso real.

### 1. Corrigir estatísticas primeiro

Antes de qualquer coisa, verifique se as estatísticas estão atualizadas. Boa parte do que
é diagnosticado como parameter sniffing é, na verdade, estimativa ruim por estatística
velha — e a correção é muito mais barata. Veja
[`estatisticas-desatualizadas.md`](estatisticas-desatualizadas.md).

### 2. `OPTIMIZE FOR UNKNOWN`

```sql
SELECT p.PedidoId, p.Data, p.Valor
FROM dbo.Pedido AS p
WHERE p.ClienteId = @ClienteId
OPTION (OPTIMIZE FOR UNKNOWN);
```

Ignora o valor farejado e usa a **densidade média** da estatística. Produz um plano
"mediano": ninguém fica ótimo, ninguém fica catastrófico.

**Quando usar:** distribuição muito desigual, sem um valor típico dominante.
**Quando não usar:** quando 95% das chamadas são de um perfil só — aí o plano mediano
penaliza a maioria para proteger a exceção.

### 3. `OPTIMIZE FOR (@parametro = valor)`

```sql
OPTION (OPTIMIZE FOR (@ClienteId = 1))
```

Fixa a otimização para um valor representativo escolhido por você.

**Quando usar:** você conhece o perfil dominante e ele é estável.
**Cuidado:** vira dívida técnica silenciosa. Se o valor deixar de ser representativo, o
plano fica ruim e ninguém lembra do porquê. **Comente no código** por que aquele valor
está ali.

### 4. `RECOMPILE`

```sql
-- No nivel da instrucao (preferivel):
SELECT ... WHERE p.ClienteId = @ClienteId
OPTION (RECOMPILE);

-- No nivel da procedure inteira (mais caro):
CREATE PROCEDURE dbo.usp_PedidosPorCliente ... WITH RECOMPILE AS ...
```

Compila um plano novo a cada execução, sempre ideal para o parâmetro do momento.

**Quando usar:** query executada **poucas vezes** e cuja variação de custo é enorme —
relatório, consulta administrativa, filtro dinâmico.
**Quando NÃO usar:** query de alta frequência. Compilar custa CPU; a mil execuções por
minuto, o remédio vira a doença. Além disso, queries com `RECOMPILE` **não aparecem** em
`sys.dm_exec_query_stats`, o que cega o monitoramento.

Prefira `OPTION (RECOMPILE)` no nível da instrução: recompila só a instrução problemática,
não a procedure inteira.

### 5. Separar em caminhos de código

Quando há dois perfis claramente distintos, o mais honesto é ter dois planos:

```sql
CREATE PROCEDURE dbo.usp_PedidosPorCliente
    @ClienteId INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @ClienteId IN (SELECT ClienteId FROM dbo.ClienteDeGrandeVolume)
        EXEC dbo.usp_PedidosPorCliente_Grande @ClienteId;
    ELSE
        EXEC dbo.usp_PedidosPorCliente_Pequeno @ClienteId;
END;
```

Cada procedure interna tem cache próprio e plano próprio. É mais verboso e é a solução
mais estável quando os perfis são realmente dois.

### 6. Variável local (padrão legado — conheça, evite)

```sql
DECLARE @ClienteLocal INT = @ClienteId;
SELECT ... WHERE p.ClienteId = @ClienteLocal;
```

O otimizador não consegue farejar o valor de uma variável local e recorre à densidade
média — efeito semelhante ao `OPTIMIZE FOR UNKNOWN`.

**Por que evitar:** é um efeito colateral, não uma intenção declarada. Quem ler o código
daqui a três anos não vai entender que aquela atribuição é uma decisão de otimização.
Use `OPTIMIZE FOR UNKNOWN`, que diz o que quer dizer. Reconheça o padrão em código legado.

### 7. Forçar plano pelo Query Store (SQL Server 2016+)

```sql
EXEC sys.sp_query_store_force_plan @query_id = <ID>, @plan_id = <ID>;
```

Fixa um plano específico sem alterar o código — útil quando não se pode fazer deploy.

**Cuidado:** o plano forçado permanece até ser removido, mesmo que os dados mudem
completamente. **Documente** cada plano forçado e revise periodicamente. Plano forçado
esquecido vira o próximo incidente.

---

## Novidades por versão

| Versão | Recurso | Efeito |
|---|---|---|
| SQL Server 2017 | Adaptive Joins, Memory Grant Feedback (Enterprise) | Ajustes automáticos que reduzem parte do problema |
| SQL Server 2019 | Intelligent Query Processing ampliado | Mais correções automáticas em tempo de execução |
| SQL Server 2022 | **Parameter Sensitive Plan optimization** | Permite múltiplos planos ativos para a mesma instrução, conforme a cardinalidade do predicado |

O PSP do SQL Server 2022 endereça diretamente este cenário, mas tem escopo e condições de
ativação próprios. Verifique o comportamento na sua carga antes de assumir que o problema
desapareceu — e mantenha o diagnóstico, porque nem toda query se qualifica.

---

## Quando NÃO tratar como parameter sniffing

- **A query é lenta para todos os parâmetros.** Aí é plano ruim, falta de índice ou
  volume. Vá para [`../indexes/encontrar-indices-ausentes.sql`](../indexes/encontrar-indices-ausentes.sql).
- **Nunca foi rápida.** Parameter sniffing implica variação.
- **Ficou lenta para todo mundo ao mesmo tempo.** Provavelmente estatística ou mudança de
  dados, não sniffing.

## Referências

- [Cache de planos de execução e reutilização](https://learn.microsoft.com/pt-br/sql/relational-databases/query-processing-architecture-guide#execution-plan-caching-and-reuse)
- [Dicas de consulta (`OPTIMIZE FOR`, `RECOMPILE`)](https://learn.microsoft.com/pt-br/sql/t-sql/queries/hints-transact-sql-query)
- [Query Store — cenários de uso](https://learn.microsoft.com/pt-br/sql/relational-databases/performance/query-store-usage-scenarios)

---

**Criado por Fábio Cerqueira**
