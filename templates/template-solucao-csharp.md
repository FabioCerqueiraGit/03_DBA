# [Título: o problema, não o nome da classe]

> Uma linha explicando o que esta solução resolve.

| | |
|---|---|
| **Compatibilidade** | .NET Framework 4.6.2+ · .NET 8+ · .NET 10 |
| **Pacotes** | `Nome.Do.Pacote` >= X.Y.Z |
| **Impacto em produção** | Descreva |

---

## Problema

O sintoma como ele aparece em produção: exceção, timeout, memória subindo, throughput
caindo. Inclua a mensagem de erro literal, porque é por ela que a pessoa vai buscar.

## Quando utilizar

## Quando NÃO utilizar

**Obrigatório.** Todo padrão tem custo. Diga quando o custo não compensa.

## Pré-requisitos

## Solução

### O que costuma estar errado

```csharp
// ❌ Errado -- e por que
```

### O jeito correto

```csharp
// ✅ Correto
```

### Legado → Intermediário → Moderno

Quando a API mudou entre plataformas, mostre os três caminhos. Não apresente a solução
moderna como se rodasse em .NET Framework.

```csharp
// .NET Framework 4.6.2+
```

```csharp
// .NET 8+ / .NET 10
```

## Como utilizar

Registro no contêiner de DI, configuração, ordem de chamada.

## Explicação

Por que o jeito errado é errado. Explique o mecanismo, não só a regra — quem entende o
mecanismo acerta no caso que o documento não previu.

## Exemplo

Exemplo completo e compilável.

## Cuidados

## Performance

Alocação, latência, contenção de thread, uso de pool. Números quando houver.

## Segurança

Segredo em configuração, validação de entrada, TLS, log de dado sensível.

## Compatibilidade

| Plataforma | Suportado | Observação |
|---|---|---|
| .NET Framework 4.6.2 – 4.8.1 | | |
| .NET 8 (LTS) | | Fim de suporte em 10/11/2026 |
| .NET 10 (LTS) | | Suporte até novembro de 2028 |

## Troubleshooting

| Sintoma | Causa provável | Correção |
|---|---|---|

## Referências

- [Documentação oficial](https://learn.microsoft.com/pt-br/dotnet/)

---

**Criado por Fábio Cerqueira**
