# Keep row lookup, command control, and payload registers close together.
ctx.createRectangularRegion('command_queue', 12, 1, 23, 12)
ctx.createRectangularRegion('command_payload', 12, 1, 25, 18)
# EBRs occupy rows 25 and 37; keep the line buffer on the controller side.
ctx.createRectangularRegion('line_buffer', 12, 20, 25, 26)
count = 0
for name, cell in ctx.cells:
    if name.startswith('memory.controller.') and any(part in name for part in (
        'head_hits', 'load_head', 'head_valid', 'lookup_valid', 'bank_safe',
        'lookup_addr', 'rows_q', 'open_q', 'run_ready', 'recovered', 'state_q',
        'delay_q', 'delay_done', 'head_same_direction', 'count_q', 'full_q',
        'empty_q', 'accept', 'mem_stb', 'mem_stall', 'we_fifo')):
        ctx.constrainCellToRegion(name, 'command_queue')
        count += 1
    elif name == 'video.scanout.lines.0.0':
        ctx.bindBel('X13/Y25/EBR0', cell, STRENGTH_USER)
    elif name.startswith('video.scanout.lines'):
        ctx.constrainCellToRegion(name, 'line_buffer')
    elif name.startswith('video.scanout.') and any(part in name for part in (
        'address_q', 'word_q', 'fetch_row', 'fetch_bank', 'setup_q', 'busy_q',
        'issued_q', 'issuing_q')):
        ctx.constrainCellToRegion(name, 'command_payload')
    elif name.startswith('fabric.crossing.memory_rst') or name.startswith('memory_reset_sync'):
        ctx.constrainCellToRegion(name, 'command_queue')
    elif name.startswith('fabric.crossing.') and any(part in name for part in (
        'issued_q', 'returned_q', 'issuing_q', 'active_q', 'line_data',
        'producer_', 'consumer_', 'get_q', 'issued_last_q',
        'request_valid_q', 'head_write', 'reply_last_q', 'empty_q')):
        ctx.constrainCellToRegion(name, 'command_payload')
    elif name.startswith('fabric.') and not name.startswith('fabric.crossing.'):
        ctx.constrainCellToRegion(name, 'command_payload')
    elif name.startswith('memory.controller.') and any(part in name for part in (
        'head_data', 'head_mask', 'head_addr', 'lookup_data', 'lookup_mask')):
        ctx.constrainCellToRegion(name, 'command_payload')
print('Constrained command control cells:', count)
