circuit LED :
  module LED :
    output io : { flip CLK : Clock, flip CLK1 : Clock, LED0 : UInt<1>, LED1 : UInt<1>}

    reg counter0 : UInt<27>, io.CLK with :
      reset => (UInt<1>("h0"), counter0) @[LED.scala 16:23]
    node _counter0_T = add(counter0, UInt<1>("h1")) @[LED.scala 17:26]
    node _counter0_T_1 = tail(_counter0_T, 1) @[LED.scala 17:26]
    counter0 <= _counter0_T_1 @[LED.scala 17:14]
    node _io_LED0_T = bits(counter0, 26, 26) @[LED.scala 19:24]
    io.LED0 <= _io_LED0_T @[LED.scala 19:13]
    reg counter1 : UInt<27>, io.CLK1 with :
      reset => (UInt<1>("h0"), counter1) @[LED.scala 23:23]
    node _counter1_T = add(counter1, UInt<1>("h1")) @[LED.scala 24:26]
    node _counter1_T_1 = tail(_counter1_T, 1) @[LED.scala 24:26]
    counter1 <= _counter1_T_1 @[LED.scala 24:14]
    node _io_LED1_T = bits(counter1, 26, 26) @[LED.scala 26:24]
    io.LED1 <= _io_LED1_T @[LED.scala 26:13]

