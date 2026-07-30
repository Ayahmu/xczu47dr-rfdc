import { use, init, type ECharts } from 'echarts/core'
import { LineChart } from 'echarts/charts'
import { GridComponent, LegendComponent, MarkPointComponent, TooltipComponent } from 'echarts/components'
import { CanvasRenderer } from 'echarts/renderers'

use([LineChart, GridComponent, LegendComponent, MarkPointComponent, TooltipComponent, CanvasRenderer])

export { init }
export type { ECharts }
