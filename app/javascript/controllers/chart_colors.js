const assetTypeColorProperties = {
  stock: "--caramelo-asset-stock",
  etf: "--caramelo-asset-etf",
  fund: "--caramelo-asset-fund",
  bond: "--caramelo-asset-bond",
  crypto: "--caramelo-asset-crypto",
  other: "--caramelo-asset-other"
}

const positionPalette = [
  "--caramelo-asset-stock",
  "--caramelo-asset-etf",
  "--caramelo-asset-fund",
  "--caramelo-asset-bond",
  "--caramelo-asset-crypto",
  "--caramelo-asset-other",
  "--caramelo-series-rose",
  "--caramelo-series-olive",
  "--caramelo-series-indigo",
  "--caramelo-series-cyan",
  "--caramelo-series-rust",
  "--caramelo-series-forest",
  "--caramelo-series-berry",
  "--caramelo-series-clay",
  "--caramelo-series-denim",
  "--caramelo-series-mustard",
  "--caramelo-series-mulberry",
  "--caramelo-series-sea-green",
  "--caramelo-series-violet",
  "--caramelo-series-slate"
]

export const themeColor = (property) => getComputedStyle(document.documentElement).getPropertyValue(property).trim()

export const stableIndex = (value) => Array.from(value).reduce(
  (hash, character) => ((hash * 31) + character.codePointAt(0)) >>> 0, 0
)

export const colorFor = (key) => {
  const assetType = key.match(/^type:(.+)$/)?.[1]
  const semanticProperty = assetType && Object.hasOwn(assetTypeColorProperties, assetType)
    ? assetTypeColorProperties[assetType]
    : null
  const property = semanticProperty || positionPalette[stableIndex(key) % positionPalette.length]
  return themeColor(property)
}

export const assetTypeColor = (identifier) => colorFor(`type:${identifier}`)
