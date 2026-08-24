# Quando usar — e quando não usar — cada padrão

> Guia de decisão, não catálogo. Todo padrão aqui resolve um problema real e cobra um preço real;
> este documento tenta dizer os dois.

| | |
|---|---|
| **Compatibilidade** | Conceitual. Exemplos em C# moderno; as ideias valem para .NET Framework. |
| **Viés declarado** | Este repositório prioriza resolver problema em produção. Onde há tensão entre pureza arquitetural e clareza operacional, o texto pende para a segunda. |

---

## A pergunta que vem antes de qualquer padrão

> **Qual problema concreto este padrão resolve no meu sistema, hoje?**

Se a resposta for "deixa mais organizado", "é boa prática" ou "assim fica preparado para o
futuro", o padrão provavelmente está sendo aplicado cedo demais. Abstração adicionada antes da
necessidade custa leitura todos os dias e paga em um cenário que talvez nunca ocorra.

O custo real de uma abstração desnecessária não é o código a mais. É que, às três da manhã, quem
está investigando precisa atravessar quatro camadas para descobrir qual SQL foi executado.

---

## Repository

**O que resolve:** isola a lógica de negócio dos detalhes de persistência e permite testar sem
banco.

**Use quando:**

- Há lógica de negócio não trivial que você quer testar sem subir banco;
- As consultas são reaproveitadas em vários lugares;
- Você precisa trocar a tecnologia de acesso a dados de forma controlada — por exemplo, substituir
  parte do Entity Framework por Dapper onde a performance exige.

**NÃO use quando:**

- **O `DbContext` do EF Core já é um Repository + Unit of Work.** Envolvê-lo em outro repositorio
  que apenas repassa chamadas adiciona uma camada sem entregar nada.
- O repositorio expõe `IQueryable<T>`. Isso vaza o modelo de persistência inteiro e anula o
  isolamento que justificava a camada.
- "Para poder trocar de banco depois." Essa troca quase nunca acontece, e quando acontece o
  repositorio não é o que impede.

```csharp
// Repositorio que nao entrega nada: e o DbSet com outro nome
public interface IRepositorioPedido
{
    IQueryable<Pedido> Query();
    void Add(Pedido pedido);
    void SaveChanges();
}

// Repositorio que entrega: a intencao do negocio esta explicita,
// a consulta e testavel e o SQL fica em um lugar so.
public interface IRepositorioPedido
{
    Task<Pedido?> ObterPorIdAsync(int id, CancellationToken ct);

    Task<IReadOnlyList<Pedido>> ObterPendentesDeFaturamentoAsync(
        DateOnly competencia, CancellationToken ct);

    Task<bool> ExisteComNotaFiscalAsync(string numero, CancellationToken ct);
}
```

---

## Unit of Work

**O que resolve:** agrupa várias alterações em uma única transação.

**Use quando:** você precisa de transação explícita entre repositórios diferentes, ou combina EF
com Dapper na mesma operação.

**NÃO use quando:** o EF Core é a única via de acesso. `SaveChangesAsync()` **já é** a unidade de
trabalho — tudo o que foi rastreado vai em uma transação. Recriar isso por cima costuma render
uma interface `IUnitOfWork` cujo único método chama `SaveChangesAsync`.

Caso legítimo: EF e Dapper compartilhando a mesma transação.

```csharp
await using var transacao = await contexto.Database.BeginTransactionAsync(ct);

try
{
    contexto.Pedidos.Add(pedido);
    await contexto.SaveChangesAsync(ct);

    // Dapper usando a MESMA conexao e a MESMA transacao
    await contexto.Database.GetDbConnection().ExecuteAsync(
        "INSERT INTO dbo.LogFaturamento (PedidoId, Valor) VALUES (@PedidoId, @Valor)",
        new { PedidoId = pedido.Id, Valor = pedido.Total },
        transaction: transacao.GetDbTransaction());

    await transacao.CommitAsync(ct);
}
catch
{
    await transacao.RollbackAsync(ct);
    throw;
}
```

> Transação longa é causa direta de bloqueio. Chamada HTTP a um parceiro **dentro** de uma
> transação aberta é um dos piores padrões possíveis: o timeout do parceiro vira bloqueio no banco.
> Ver [`sql-server/troubleshooting/`](../sql-server/troubleshooting/).

---

## Service Layer

**O que resolve:** dá um lugar para a lógica de negócio que não pertence nem ao controller nem à
entidade.

**Use quando:** a operação coordena várias entidades, ou envolve efeito colateral externo (e-mail,
fila, integração).

**NÃO use quando:** o "serviço" apenas repassa a chamada para o repositorio. Um
`ServicoCliente.ObterPorId` que chama `RepositorioCliente.ObterPorId` é ruído. Nesse caso o
controller pode falar com o repositorio diretamente — e isso não é dívida técnica, é ausência de
camada desnecessária.

---

## CQRS

**O que resolve:** leitura e escrita têm requisitos diferentes — e aí podem ter modelos, e até
bancos, diferentes.

**Use quando:**

- A carga de leitura é muito maior que a de escrita e precisa escalar separadamente;
- As telas de consulta exigem projeções que não cabem no modelo de domínio sem distorcê-lo;
- Existe réplica de leitura, e as consultas devem ir para lá.

Um meio-termo bastante útil, sem toda a cerimônia: **escrita pelo EF, leitura por Dapper**.

```csharp
// Escrita: modelo rico, validacao, rastreamento
await _contexto.SaveChangesAsync(ct);

// Leitura: SQL direto, projecao exata, sem tracking, com o plano sob controle
const string sql = @"
    SELECT p.Id, p.Numero, c.Nome AS NomeCliente, p.Total
      FROM dbo.Pedido AS p
      JOIN dbo.Cliente AS c ON c.Id = p.ClienteId
     WHERE p.Status = @Status
     ORDER BY p.CriadoEm DESC
     OFFSET @Pular ROWS FETCH NEXT @Quantidade ROWS ONLY;";

var linhas = await _conexao.QueryAsync<PedidoNaLista>(sql, parametros);
```

**NÃO use quando:** o sistema é CRUD. CQRS completo — com barramento, handlers e modelo de leitura
separado — em um cadastro simples multiplica arquivos e não resolve problema nenhum.

> **Atenção à confusão mais comum:** CQRS não exige Event Sourcing, nem mediator, nem dois bancos.
> Separar o caminho de leitura do de escrita já é CQRS.

---

## Mediator

**O que resolve:** desacopla quem dispara uma operação de quem a executa, e dá um ponto único para
comportamento transversal (validação, log, transação) via pipeline.

**Use quando:** há muitos casos de uso e o comportamento transversal se repete em todos.

**NÃO use quando:**

- O sistema tem poucos casos de uso. Substituir uma chamada de método por um `Send(comando)` que
  resolve o handler por reflexão custa navegabilidade: a IDE deixa de mostrar quem chama quem.
- A equipe está adotando o padrão por ser popular. O ganho é o pipeline; se você não vai usar o
  pipeline, injetar o handler diretamente entrega o mesmo com menos indireção.

---

## SOLID, sem cerimônia

Os cinco princípios traduzidos para o que realmente muda no dia a dia:

| Princípio | Na prática | Sintoma de violação |
|---|---|---|
| **S** — responsabilidade única | Uma classe muda por um motivo só | Classe de 2.000 linhas que aparece em todo commit |
| **O** — aberto/fechado | Adicionar caso novo sem editar o existente | `switch` gigante que cresce a cada regra nova |
| **L** — substituição de Liskov | A implementação honra o contrato | `throw new NotSupportedException()` em método da interface |
| **I** — segregação de interface | Interfaces pequenas e focadas | Dublê de teste que precisa implementar 15 métodos para usar um |
| **D** — inversão de dependência | Dependa de abstração, não de concreto | `new SqlConnection(...)` dentro da regra de negócio |

**O mais valioso em código legado é o D** — e não exige reescrita. Trocar um `new` escondido por um
parâmetro de construtor já torna a classe testável, sem tocar em quem chama. Ver o estágio
intermediário em
[`dotnet/dependency-injection/`](../dotnet/dependency-injection/tempos-de-vida-e-dependencia-cativa.md).

**O mais mal aplicado é o I.** Interface com uma única implementação, criada "por princípio", não
segrega nada — só duplica a assinatura em dois arquivos. Interface se justifica quando existe
segunda implementação **ou** quando o dublê de teste é necessário.

---

## Clean Architecture

**O que resolve:** o domínio deixa de depender de framework, banco e interface, o que o torna
testável e estável.

**Use quando:** o domínio tem regra de negócio genuína — cálculo, validação complexa, máquina de
estados — e o sistema tem vida longa prevista.

**NÃO use quando:** o sistema é essencialmente CRUD com validação simples. Quatro projetos, DTOs
em cada fronteira e mapeamento entre eles, para gravar um cadastro, é custo puro.

> **O sinal de alerta:** se, para adicionar um campo, é preciso alterar sete arquivos em quatro
> projetos, a arquitetura está cobrando mais do que entrega. Isso pode significar que o sistema não
> precisava dela — ou que as fronteiras foram desenhadas no lugar errado.

---

## Padrões para sistema legado

Estes têm prioridade sobre todos os anteriores quando se trabalha com código antigo, porque
permitem melhorar **sem** reescrever:

| Padrão | Para quê |
|---|---|
| **Strangler Fig** | Substituir o sistema aos poucos, rota por rota, com o antigo funcionando |
| **Anti-Corruption Layer** | Impedir que o modelo do sistema antigo contamine o novo |
| **Adapter** | Fazer o legado falar com uma API moderna sem alterar o legado |
| **Facade** | Dar uma porta de entrada limpa a um subsistema confuso |
| **Branch by Abstraction** | Trocar uma implementação gradualmente, com as duas convivendo |

Detalhamento em [`sistemas-legados/`](../sistemas-legados/) e no caminho incremental descrito em
[`aspnet/mapa-de-versoes-e-equivalencias.md`](../aspnet/mapa-de-versoes-e-equivalencias.md).

---

## Referências

- [Microsoft Learn — Design a DDD-oriented microservice (padrões de repositório e agregado)](https://learn.microsoft.com/dotnet/architecture/microservices/microservice-ddd-cqrs-patterns/)
- [Microsoft Learn — CQRS pattern](https://learn.microsoft.com/azure/architecture/patterns/cqrs)
- [Microsoft Learn — Strangler Fig pattern](https://learn.microsoft.com/azure/architecture/patterns/strangler-fig)
- [Microsoft Learn — Anti-corruption Layer pattern](https://learn.microsoft.com/azure/architecture/patterns/anti-corruption-layer)
- [Microsoft Learn — EF Core: transações](https://learn.microsoft.com/ef/core/saving/transactions)

---

**Criado por Fábio Cerqueira**
