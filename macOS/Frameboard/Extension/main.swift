import CoreMediaIO
import Foundation

let source = FrameboardProvider()
CMIOExtensionProvider.startService(provider: source.provider)
RunLoop.main.run()
