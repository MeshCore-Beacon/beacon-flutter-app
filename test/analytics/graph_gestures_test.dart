import 'package:beacon/features/analytics/network_canvas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'graph pinches and rotates from the empty viewport and still taps nodes',
    (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      var tapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 375,
              height: 700,
              child: GraphViewport(
                controller: controller,
                child: SizedBox(
                  width: 720,
                  height: 720,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 40,
                        top: 40,
                        child: GestureDetector(
                          onTap: () => tapped = true,
                          child: const SizedBox(
                            width: 40,
                            height: 40,
                            child: ColoredBox(color: Colors.blue),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final a = await tester.startGesture(const Offset(120, 550), pointer: 1);
      final b = await tester.startGesture(const Offset(240, 550), pointer: 2);
      await a.moveTo(const Offset(90, 510));
      await b.moveTo(const Offset(270, 590));
      await tester.pump();
      await a.moveTo(const Offset(60, 470));
      await b.moveTo(const Offset(300, 630));
      await tester.pump();
      expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.2));
      expect(controller.value.entry(1, 0).abs(), greaterThan(.1));
      await a.up();
      await b.up();
      controller.value = Matrix4.identity();
      await tester.pump();
      await tester.tapAt(const Offset(60, 60));
      expect(tapped, isTrue);
      final pan = await tester.startGesture(const Offset(150, 550));
      await pan.moveBy(const Offset(30, 0));
      await tester.pump();
      await pan.moveBy(const Offset(40, 20));
      await pan.up();
      await tester.pump();
      expect(controller.value.getTranslation().x, greaterThan(0));
      expect(tester.takeException(), isNull);
    },
  );
}
