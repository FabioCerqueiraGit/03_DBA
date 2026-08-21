# Modernizar sem reescrever — Strangler Fig, Anti-Corruption Layer e o resto

> "Vamos reescrever do zero" é a decisão de arquitetura mais cara e mais frequentemente
> errada. Este documento reúne as estratégias que permitem modernizar **enquanto** o
> sistema continua no ar e gerando receita.

| | |
|---|---|
| **Contexto** | .NET Framework, WebForms, MVC 5, WCF, EF6, monolito |
| **Impacto** | Alto — decisões aqui duram anos |

---

## Por que reescrever do zero costuma falhar

O argumento a favor é sempre o mesmo: o código está ruim, ninguém entende, a stack é
antiga. Tudo verdade. O que o argumento ignora:

1. **O sistema antigo funciona.** Ele contém anos de regras de negócio descobertas na
   prova, casos de exceção e correções que ninguém documentou. Boa parte dessas regras só
   existe no código.
2. **O sistema antigo não para de evoluir.** Enquanto a reescrita acontece, o legado
   recebe demandas legais, fiscais e de negócio. Você passa a manter dois sistemas.
3. **A data de corte nunca chega.** O novo está sempre "quase pronto", porque o alvo se
   move.
4. **Não há valor até o fim.** Dezoito meses sem nenhuma entrega é tempo demais para
   qualquer patrocínio sobreviver.

A modernização incremental inverte isso: entrega valor desde a primeira semana, e o risco
de cada passo é pequeno o suficiente para ser revertido.

> Existe caso legítimo de reescrita: sistema pequeno, plataforma sem saída, ou regra de
> negócio que será substituída de qualquer forma. O erro é tratar reescrita como padrão.

---

## Strangler Fig — o padrão central

O nome vem da figueira-mata-pau, que cresce em volta de outra árvore até substituí-la
completamente. A árvore antiga sustenta a nova durante todo o processo.

```text
FASE 1 — fachada na frente do legado

    Cliente  ->  [ Fachada / Proxy ]  ->  Sistema legado

FASE 2 — a fachada desvia UMA funcionalidade

    Cliente  ->  [ Fachada ]  -+->  Sistema legado      (o resto)
                               \->  Servico novo        (uma funcionalidade)

FASE 3 — mais funcionalidades migram

    Cliente  ->  [ Fachada ]  -+->  Sistema legado      (o que sobrou)
                               \->  Servicos novos      (a maior parte)

FASE 4 — o legado é desligado

    Cliente  ->  [ Fachada ]  ->  Servicos novos
```

### O que serve de fachada

| Opção | Quando |
|---|---|
| **URL Rewrite / ARR no IIS** | O legado já está no IIS. Baixo custo, sem código |
| **YARP** (proxy reverso em .NET) | Precisa de roteamento com lógica, e a equipe é de .NET |
| **API Gateway** | Já existe um na organização |
| **Balanceador / WAF** | Roteamento simples por caminho |

Exemplo com URL Rewrite no `web.config` do legado:

```xml
<system.webServer>
  <rewrite>
    <rules>
      <!-- /api/pedidos/* passa a ser atendido pelo servico novo.
           O restante continua no legado, sem alteracao. -->
      <rule name="DesviarPedidosParaServicoNovo" stopProcessing="true">
        <match url="^api/pedidos/(.*)" />
        <action type="Rewrite" url="https://&lt;HOST-DO-SERVICO-NOVO&gt;/api/pedidos/{R:1}" />
      </rule>
    </rules>
  </rewrite>
</system.webServer>
```

### Por onde começar

Escolha o primeiro pedaço com estes critérios, nesta ordem:

1. **Fronteira clara** — pouco acoplamento com o resto.
2. **Valor visível** — algo que o negócio perceba, para sustentar o patrocínio.
3. **Risco controlável** — se der errado, o desvio volta para o legado em minutos.
4. **Sem ser o coração do sistema** — não comece pelo faturamento.

Candidatos típicos de primeiro passo: relatórios, consultas, catálogo, autenticação,
notificações.

---

## Anti-Corruption Layer (ACL)

O maior risco de integrar novo com velho é o modelo do legado contaminar o código novo. Se
o serviço novo trabalhar com `CLI_TP_SIT` e datas em `VARCHAR(8)`, ele nasce legado.

A ACL é uma camada de tradução que isola os dois modelos:

```csharp
// ---------- Modelo do legado (nao vaza para dentro) ----------
internal sealed class ClienteLegado
{
    public string CLI_COD    { get; set; } = "";
    public string CLI_NOM    { get; set; } = "";
    public string CLI_TP_SIT { get; set; } = "";   // "A", "I", "B"
    public string CLI_DT_CAD { get; set; } = "";   // "20260315"
}

// ---------- Modelo do dominio novo ----------
public sealed record Cliente(
    ClienteId Id,
    string Nome,
    SituacaoDoCliente Situacao,
    DateOnly CadastradoEm);

public enum SituacaoDoCliente { Ativo, Inativo, Bloqueado }

// ---------- A camada de traducao ----------
internal static class TradutorDeCliente
{
    public static Cliente ParaDominio(ClienteLegado origem)
    {
        var situacao = origem.CLI_TP_SIT switch
        {
            "A" => SituacaoDoCliente.Ativo,
            "I" => SituacaoDoCliente.Inativo,
            "B" => SituacaoDoCliente.Bloqueado,
            _   => throw new InvalidOperationException(
                       $"Situacao desconhecida no legado: '{origem.CLI_TP_SIT}'.")
        };

        if (!DateOnly.TryParseExact(origem.CLI_DT_CAD, "yyyyMMdd",
                                    CultureInfo.InvariantCulture,
                                    DateTimeStyles.None, out var cadastro))
        {
            throw new InvalidOperationException(
                $"Data de cadastro invalida no legado: '{origem.CLI_DT_CAD}'.");
        }

        return new Cliente(
            new ClienteId(origem.CLI_COD.Trim()),
            origem.CLI_NOM.Trim(),
            situacao,
            cadastro);
    }
}
```

Três regras que fazem a ACL funcionar:

1. **O modelo do legado é `internal`.** Se ele aparece na assinatura pública de um serviço
   novo, a barreira já vazou.
2. **Falhe alto na tradução.** Um valor inesperado deve lançar, não virar um `default`
   silencioso — dado ruim que passa pela barreira é pior do que erro visível.
3. **A tradução é o lugar de documentar as regras esquecidas.** O `switch` acima é,
   frequentemente, a única documentação existente daqueles códigos.

---

## Introduzir DI em código legado

Sistema legado costuma instanciar tudo com `new` dentro dos métodos, o que impede teste e
substituição.

```csharp
// Antes
public class ServicoDePedido
{
    public void Processar(int pedidoId)
    {
        var repositorio = new RepositorioDePedido();     // acoplado
        var email       = new ServicoDeEmail();          // acoplado
        // ...
    }
}
```

**Passo 1 — extrair interface e construtor, mantendo o padrão antigo funcionando:**

```csharp
public class ServicoDePedido
{
    private readonly IRepositorioDePedido _repositorio;
    private readonly IServicoDeEmail _email;

    // Construtor novo, usado por quem ja migrou
    public ServicoDePedido(IRepositorioDePedido repositorio, IServicoDeEmail email)
    {
        _repositorio = repositorio;
        _email = email;
    }

    // Construtor sem parametros: mantem o codigo antigo compilando.
    // Marcado como obsoleto para que o compilador aponte cada uso restante.
    [Obsolete("Use o construtor com dependencias. Este existe apenas para a transicao.")]
    public ServicoDePedido()
        : this(new RepositorioDePedido(), new ServicoDeEmail())
    {
    }
}
```

O `[Obsolete]` transforma a migração em uma lista de avisos do compilador — finita,
visível e que diminui a cada commit.

**Passo 2 — contêiner de DI.** `Microsoft.Extensions.DependencyInjection` funciona em .NET
Framework e permite usar o mesmo estilo do .NET moderno, o que facilita a migração futura.

**Passo 3 — remover o construtor obsoleto** quando o último aviso sumir.

---

## Introduzir logging

Sistema legado sem log é sistema impossível de diagnosticar. `Microsoft.Extensions.Logging`
também roda em .NET Framework e dá acesso aos provedores modernos (Serilog, NLog e outros).

Onde instrumentar primeiro, com melhor retorno:

1. **Fronteiras**: entrada e saída de cada integração externa.
2. **Exceções**: todo `catch` que hoje engole erro em silêncio.
3. **Decisões de negócio**: qual caminho foi tomado, e por quê.
4. **Correlation ID**: um identificador por requisição, propagado por toda a cadeia.

O correlation ID é o item de maior impacto: sem ele, correlacionar o log do legado com o
do serviço novo é impossível — e essa correlação é exatamente o que se precisa durante a
transição.

```text
Server=<SERVIDOR>;Database=<BANCO>;...;Application Name=<SISTEMA>-legado
```

Diferenciar o `Application Name` do legado e do serviço novo permite ver, nas DMVs do SQL
Server, exatamente quanto de carga já migrou. Veja
[`../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql`](../sql-server/monitoramento/sessoes-e-requests-em-execucao.sql).

---

## Criar testes em código sem testes

O paradoxo clássico: para testar é preciso refatorar; para refatorar com segurança é
preciso testar.

A saída são **testes de caracterização**: em vez de testar o que o código *deveria* fazer,
registre o que ele **de fato faz hoje** e trave esse comportamento.

```csharp
[Fact]
public void CalculoDeDesconto_DeveManterOComportamentoAtual()
{
    // Nao sabemos se 12,5% e "certo". Sabemos que e o que o sistema faz hoje,
    // e que mudar isso sem intencao seria uma regressao.
    var servico = new CalculadoraDeDesconto();

    var resultado = servico.Calcular(valor: 1000m, categoria: "OURO", quantidade: 10);

    Assert.Equal(125.00m, resultado);
}
```

Esses testes não validam a regra: **protegem contra mudança acidental**. É exatamente disso
que se precisa antes de refatorar.

Comece pelos caminhos de maior valor e maior risco. Cobertura total não é o objetivo —
rede de segurança para a próxima mudança é.

---

## Roteiro de migração de plataforma

Quando o objetivo é sair do .NET Framework:

| Etapa | O que fazer |
|---|---|
| 1 | Rodar o **.NET Upgrade Assistant** para mapear o esforço e as incompatibilidades |
| 2 | Converter os `.csproj` para o formato SDK — continua compilando em .NET Framework |
| 3 | Extrair a lógica de negócio para bibliotecas **.NET Standard 2.0**, que rodam nas duas plataformas |
| 4 | Substituir o que não tem equivalente: `System.Web`, `ConfigurationManager`, WCF de servidor |
| 5 | Migrar projeto a projeto, começando pelas bibliotecas sem dependência de web |
| 6 | Migrar a camada web por último — é a que mais depende de `System.Web` |

**.NET Standard 2.0 é a ponte.** Uma biblioteca nele é consumida tanto pelo legado em .NET
Framework quanto pelo serviço novo em .NET 10 — permitindo compartilhar a regra de negócio
durante a transição inteira, sem duplicar.

Substituições que sempre aparecem:

| .NET Framework | .NET moderno |
|---|---|
| `System.Web.HttpContext` | `Microsoft.AspNetCore.Http.HttpContext` |
| `ConfigurationManager.AppSettings` | `IConfiguration` |
| `WebForms` | Razor Pages, MVC ou API + front separado |
| WCF servidor | CoreWCF, ou expor REST/gRPC |
| `System.Drawing.Common` | `ImageSharp`, `SkiaSharp` |
| `HttpWebRequest` | `HttpClient` |

---

## O que **não** fazer

| Antipadrão | Por quê |
|---|---|
| **Reescrever tudo em paralelo** | Duas bases evoluindo, data de corte que nunca chega |
| **Migrar a plataforma e refatorar a arquitetura no mesmo passo** | Se quebrar, você não sabe qual mudança causou. Separe |
| **Começar pelo núcleo** | Maior risco, menor chance de reverter |
| **Compartilhar o banco sem contrato** | Dois sistemas escrevendo na mesma tabela sem regra vira corrupção de dado |
| **Deixar a fachada acumular regra de negócio** | Ela vira um terceiro sistema a manter |
| **Migrar sem monitorar** | Sem métrica, não dá para provar que o novo está melhor — nem que está pior |

Sobre o banco compartilhado: durante a transição é quase inevitável que os dois sistemas
usem a mesma base. Estabeleça por escrito **quem é dono de escrita de cada tabela**. Sem
isso, a corrupção de dado aparece semanas depois, sem rastro.

---

## Como saber que está dando certo

| Indicador | O que observa |
|---|---|
| Percentual de tráfego no serviço novo | Progresso real da migração |
| Taxa de erro comparada entre os dois | O novo está melhor mesmo? |
| Latência p95 comparada | Idem |
| Número de funcionalidades ainda no legado | O que falta |
| Tempo médio para entregar uma mudança | O objetivo real da modernização |

O último é o que justifica o investimento diante do negócio. Modernizar não é sobre stack:
é sobre conseguir entregar mais rápido e com menos risco.

## Referências

- [Padrão Strangler Fig](https://learn.microsoft.com/pt-br/azure/architecture/patterns/strangler-fig)
- [Padrão Anti-Corruption Layer](https://learn.microsoft.com/pt-br/azure/architecture/patterns/anti-corruption-layer)
- [Portar do .NET Framework para o .NET](https://learn.microsoft.com/pt-br/dotnet/core/porting/)
- [.NET Upgrade Assistant](https://learn.microsoft.com/pt-br/dotnet/core/porting/upgrade-assistant-overview)

---

**Criado por Fábio Cerqueira**
