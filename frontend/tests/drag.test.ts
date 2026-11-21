import {XYDrag, type InternalNodeBase, type NodeBase, type XYPosition} from '@xyflow/system';
import {describe, expect, it, vi} from 'vitest';

describe('canvas node dragging with a single pointer movement', () => {
  it('retains the mouse-down offset and commits the full movement with a zero drag threshold', () => {
    const view = document.defaultView!;
    const canvas = document.createElement('div');
    const nodeElement = document.createElement('div');
    const handle = document.createElement('div');
    handle.className = 'node-header';
    nodeElement.append(handle);
    canvas.append(nodeElement);
    document.body.append(canvas);

    const node: NodeBase = {id: 'mic', position: {x: 0, y: 0}, data: {}, draggable: true};
    const internal: InternalNodeBase = {
      ...node,
      measured: {width: 248, height: 160},
      internals: {positionAbsolute: {x: 0, y: 0}, userNode: node, z: 0, isParent: false},
    };
    const updates: {position: XYPosition; dragging?: boolean}[] = [];
    const onDragStop = vi.fn();
    const mouse = (type: string, x: number, y: number, buttons: number) => {
      const event = new MouseEvent(type, {bubbles: true, cancelable: true, clientX: x, clientY: y, button: 0, buttons});
      // Vitest wraps jsdom's Window; set the view after construction so d3 can
      // attach its real window listeners without jsdom rejecting that wrapper.
      Object.defineProperty(event, 'view', {value: view});
      return event;
    };
    const drag = XYDrag({
      getStoreItems: () => ({
        nodes: [node], edges: [], nodeLookup: new Map([['mic', internal]]),
        nodeExtent: [[-Infinity, -Infinity], [Infinity, Infinity]],
        snapGrid: [1, 1], snapToGrid: false, nodeOrigin: [0, 0],
        multiSelectionActive: false, domNode: canvas, transform: [0, 0, 1],
        autoPanOnNodeDrag: false, nodesDraggable: true, selectNodesOnDrag: true,
        nodeDragThreshold: 0, panBy: async () => false,
        unselectNodesAndEdges: () => {},
        updateNodePositions: (items, dragging) => {
          const moved = items.get('mic');
          if (moved) updates.push({position: {...moved.position}, dragging});
        },
      }),
      onDragStop,
    });

    try {
      drag.update({domNode: nodeElement, nodeId: 'mic', handleSelector: '.node-header', isSelectable: true});
      handle.dispatchEvent(mouse('mousedown', 10, 10, 1));
      // Some native/browser automation emits only this final movement. Starting
      // the drag here would lose the pointer's original offset from the node.
      view.dispatchEvent(mouse('mousemove', 30, 40, 1));
      handle.dispatchEvent(mouse('mouseup', 30, 40, 0));

      expect(updates).toEqual([
        {position: {x: 20, y: 30}, dragging: true},
        {position: {x: 20, y: 30}, dragging: false},
      ]);
      expect(onDragStop).toHaveBeenCalledTimes(1);
    } finally {
      drag.destroy();
      canvas.remove();
    }
  });
});
