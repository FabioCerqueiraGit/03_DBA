# Serialização JSON — `System.Text.Json` e `Newtonsoft.Json`

> "O JSON não desserializa" quase sempre tem uma de quatro causas: diferença de
> maiúsculas/minúsculas, tipo incompatível, data com fuso, ou número com vírgula.

| | |
|---|---|
| **Compatibilidade** | `System.Text.Json`: .NET Core 3.0+ · `Newtonsoft.Json`: todas as plataformas |
| **Impacto** | Erro de fuso ou de cultura corrompe dado em silêncio |

---

## Qual biblioteca usar

| | `System.Text.Json` | `Newtonsoft.Json` |
|---|---|---|
| **Disponibilidade** | Nativo a partir do .NET Core 3.0 | Pacote NuGet, funciona em tudo |
| **Desempenho** | Mais rápido e com menos alocação | Mais lento |
| **Case-sensitive por padrão** | **Sim** | Não |
| **Flexibilidade** | Menor | Muito maior (`JsonConverter`, `JObject`, referências cíclicas) |
| **.NET Framework** | Disponível via pacote, com limitações | O caminho natural |

**Código novo em .NET moderno:** `System.Text.Json`.
**Legado, ou necessidade de recursos avançados:** `Newtonsoft.Json`.

---

## A armadilha número um: case sensitivity

```csharp
// A API devolve:  { "pedidoId": 42, "valorTotal": 199.90 }
public record Pedido(int PedidoId, decimal ValorTotal);

// ❌ System.Text.Json e case-sensitive POR PADRAO.
//    O resultado nao e erro: e um objeto com PedidoId = 0 e ValorTotal = 0.
var pedido = JsonSerializer.Deserialize<Pedido>(json);
```

Este é o comportamento mais perigoso da biblioteca: ele **não lança exceção**. Você recebe
um objeto preenchido com valores padrão e só descobre o problema quando o dado errado
chega ao banco.

```csharp
// ✅ Configuracao unica, reutilizada em toda a aplicacao
private static readonly JsonSerializerOptions Opcoes = new()
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    PropertyNameCaseInsensitive = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    NumberHandling = JsonNumberHandling.AllowReadingFromString
};

var pedido = JsonSerializer.Deserialize<Pedido>(json, Opcoes);
```

> **Crie a instância de `JsonSerializerOptions` uma vez** e reutilize. Criar uma nova a cada
> chamada descarta o cache de metadados interno e degrada muito o desempenho.

Em ASP.NET Core, configure globalmente:

```csharp
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
    options.SerializerOptions.PropertyNameCaseInsensitive = true;
});
```

---

## Datas e fusos — onde o dado se corrompe em silêncio

```csharp
// ❌ DateTime sem fuso: o significado depende de quem le
public record Evento(DateTime Ocorrido);

// ✅ DateTimeOffset carrega o deslocamento
public record Evento(DateTimeOffset Ocorrido);
```

`System.Text.Json` serializa `DateTime` e `DateTimeOffset` no formato **ISO 8601**, que é o
correto. O problema não é o formato: é o `DateTime.Kind`.

| `Kind` | O que acontece na serialização |
|---|---|
| `Utc` | Sai com `Z` — sem ambiguidade |
| `Local` | Sai com o deslocamento da máquina — muda conforme o servidor |
| `Unspecified` | Sai **sem** informação de fuso — o receptor adivinha |

O cenário clássico de bug: o servidor de aplicação está em UTC, o de banco no horário de
Brasília, e uma data gravada como `Unspecified` é interpretada de forma diferente em cada
ponta. A diferença de três horas só aparece em relatório de fechamento.

**Regra prática:** trafegue e armazene em **UTC**; converta para o fuso local apenas na
apresentação.

```csharp
// Conversao para exibicao, usando o banco de dados de fusos do sistema
var fuso = TimeZoneInfo.FindSystemTimeZoneById("America/Sao_Paulo");
var local = TimeZoneInfo.ConvertTime(evento.Ocorrido, fuso);
```

> Os identificadores no estilo IANA (`America/Sao_Paulo`) funcionam no Windows a partir do
> .NET 6; em versões anteriores no Windows, use `"E. South America Standard Time"`.

---

## Números e cultura

```csharp
// ❌ ToString() usa a cultura corrente.
//    Em pt-BR isso gera "199,90" -- que quebra o JSON.
var json = "{\"valor\": " + valor.ToString() + "}";
```

Os serializadores usam cultura invariante por padrão, e está certo. O problema aparece
quando alguém monta JSON à mão, ou converte números para texto antes de serializar.

**Nunca monte JSON por concatenação.** Serialize sempre.

E, para valor monetário, use `decimal` — nunca `double`:

```csharp
// ❌ double acumula erro de arredondamento
public record Item(string Produto, double Valor);

// ✅
public record Item(string Produto, decimal Valor);
```

Quando a API alheia devolve número como string (`"valor": "199.90"`),
`JsonNumberHandling.AllowReadingFromString` resolve sem precisar de conversor próprio.

---

## Conversor personalizado

Para formatos que a biblioteca não entende — comum em APIs de órgãos públicos e sistemas
legados:

```csharp
public sealed class ConversorDeDataCompacta : JsonConverter<DateOnly>
{
    private const string Formato = "yyyyMMdd";

    public override DateOnly Read(ref Utf8JsonReader reader,
                                  Type typeToConvert,
                                  JsonSerializerOptions options)
    {
        var texto = reader.GetString();

        return DateOnly.TryParseExact(texto, Formato,
                                      CultureInfo.InvariantCulture,
                                      DateTimeStyles.None, out var data)
            ? data
            : throw new JsonException($"Data invalida: '{texto}'. Esperado {Formato}.");
    }

    public override void Write(Utf8JsonWriter writer,
                               DateOnly valor,
                               JsonSerializerOptions options)
        => writer.WriteStringValue(valor.ToString(Formato, CultureInfo.InvariantCulture));
}
```

```csharp
Opcoes.Converters.Add(new ConversorDeDataCompacta());
```

Repare que o conversor **lança** quando o valor é inválido, em vez de devolver um padrão.
Falhar alto na fronteira é melhor do que propagar dado errado para dentro.

---

## Newtonsoft.Json — configuração equivalente

```csharp
private static readonly JsonSerializerSettings Configuracao = new JsonSerializerSettings
{
    ContractResolver = new CamelCasePropertyNamesContractResolver(),
    NullValueHandling = NullValueHandling.Ignore,
    DateTimeZoneHandling = DateTimeZoneHandling.Utc,
    DateFormatHandling = DateFormatHandling.IsoDateFormat,
    FloatParseHandling = FloatParseHandling.Decimal,

    // Evita loop infinito em grafos com referencia circular
    ReferenceLoopHandling = ReferenceLoopHandling.Ignore
};
```

`DateTimeZoneHandling.Utc` é o ajuste que mais evita bug de fuso em legado.
`FloatParseHandling.Decimal` evita que valores monetários virem `double`.

---

## Erros e o que significam

| Erro | Causa | Correção |
|---|---|---|
| Objeto vem com propriedades zeradas, sem exceção | `PropertyNameCaseInsensitive` desligado | Configurar as opções |
| `The JSON value could not be converted to System.Int32` | Tipo diferente do esperado (número como string) | `AllowReadingFromString`, ou corrigir o modelo |
| `A possible object cycle was detected` | Referência circular no grafo | `ReferenceHandler.IgnoreCycles`, ou usar DTOs |
| Data com três horas de diferença | `DateTime.Kind` inadequado | `DateTimeOffset` e UTC |
| Acentos corrompidos | Encoding diferente de UTF-8 | Garantir UTF-8 nas duas pontas |
| Barra invertida escapada demais | JSON serializado duas vezes | Procurar o `JsonConvert.SerializeObject` extra |

O último é sutil: um objeto que já é string JSON, serializado de novo, vira uma string com
aspas escapadas. Se o corpo da requisição começa com `"{\"` em vez de `{"`, é isso.

---

## Segurança

**Não serialize entidades de banco diretamente.** Use DTOs.

Uma entidade serializada expõe tudo que tem — inclusive campos que você esqueceu que
existiam (`SenhaHash`, `TokenDeRecuperacao`, `ObservacaoInterna`). E, no EF6 com lazy
loading ligado, a serialização ainda percorre o grafo disparando uma query por navegação.

```csharp
// ❌ Expoe o modelo inteiro, hoje e a cada campo novo que alguem adicionar
return Ok(await _context.Clientes.FindAsync(id));

// ✅ Contrato explicito
return Ok(await _context.Clientes
    .Where(c => c.ClienteId == id)
    .Select(c => new ClienteDto(c.ClienteId, c.Nome, c.Email))
    .SingleOrDefaultAsync(ct));
```

O DTO também protege contra *over-posting*: sem ele, um campo enviado pelo cliente pode
alterar propriedade que não deveria ser editável.

---

## Checklist

- [ ] `JsonSerializerOptions` criado **uma vez** e reutilizado.
- [ ] `PropertyNameCaseInsensitive` habilitado ao consumir API de terceiro.
- [ ] `DateTimeOffset` ou UTC explícito em toda data que trafega.
- [ ] `decimal` para valor monetário.
- [ ] Nenhum JSON montado por concatenação de string.
- [ ] DTOs em vez de entidades nas fronteiras.
- [ ] Conversores personalizados lançam em valor inválido.
- [ ] UTF-8 garantido nas duas pontas.

## Referências

- [Serialização JSON no .NET](https://learn.microsoft.com/pt-br/dotnet/standard/serialization/system-text-json/)
- [Migrar do Newtonsoft.Json para o System.Text.Json](https://learn.microsoft.com/pt-br/dotnet/standard/serialization/system-text-json/migrate-from-newtonsoft)
- [Conversores personalizados](https://learn.microsoft.com/pt-br/dotnet/standard/serialization/system-text-json/converters-how-to)

---

**Criado por Fábio Cerqueira**
