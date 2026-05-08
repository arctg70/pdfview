#!/usr/bin/env python3
"""PDF Viewer using MuPDF and tkinter."""

import sys
import os

# Ensure mupdf is importable from Homebrew
_site_packages = '/opt/homebrew/lib/python3.14/site-packages'
if _site_packages not in sys.path:
    sys.path.insert(0, _site_packages)

import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from PIL import Image, ImageTk

import mupdf

# Shared RGB colorspace reference
_RGB_CS = mupdf.FzColorspace(mupdf.FzColorspace.Fixed_RGB)


class PDFDocument:
    """Wrap a MuPDF document, providing page rendering."""

    def __init__(self, path: str):
        self.path = path
        self.doc = mupdf.FzDocument(path)
        self.page_count = self.doc.fz_count_pages()

    def get_page_pixmap(self, page_number: int, zoom: float = 1.0):
        """Render a page to a PIL Image at the given zoom level."""
        page = self.doc.fz_load_page(page_number)
        ctm = mupdf.FzMatrix(zoom, 0, 0, zoom, 0, 0)
        pix = page.fz_new_pixmap_from_page(ctm, _RGB_CS, 0)
        w, h = pix.w(), pix.h()
        samples = pix.fz_pixmap_samples_memoryview()
        return Image.frombytes('RGB', (w, h), samples)

    def get_page_size(self, page_number: int):
        """Return (width, height) in points at zoom=1."""
        page = self.doc.fz_load_page(page_number)
        rect = page.fz_bound_page()
        return rect.x1 - rect.x0, rect.y1 - rect.y0

    def close(self):
        self.doc = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class PDFViewer(tk.Tk):
    TITLE = 'MuPDF PDF Viewer'
    MIN_WIDTH = 600
    MIN_HEIGHT = 400
    DEFAULT_W = 900
    DEFAULT_H = 700

    ZOOM_STEP = 1.25
    MIN_ZOOM = 0.1
    MAX_ZOOM = 20.0

    def __init__(self):
        super().__init__()
        self.title(self.TITLE)
        self.geometry(f'{self.DEFAULT_W}x{self.DEFAULT_H}')
        self.minsize(self.MIN_WIDTH, self.MIN_HEIGHT)

        self._doc: PDFDocument | None = None
        self._page_images: dict[int, ImageTk.PhotoImage] = {}
        self._current_page = 0
        self._zoom = 1.0
        self._fit_mode = None  # 'width', 'page', or None

        self._build_ui()
        self._bind_keys()

        if len(sys.argv) > 1:
            path = os.path.abspath(sys.argv[1])
            if os.path.isfile(path):
                self.open_file(path)

    # ── UI construction ───────────────────────────────────────────

    def _build_ui(self):
        toolbar = ttk.Frame(self, padding=4)
        toolbar.pack(side=tk.TOP, fill=tk.X)

        ttk.Button(toolbar, text='Open', command=self._cmd_open).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text='◀', width=3, command=self._cmd_prev_page).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text='▶', width=3, command=self._cmd_next_page).pack(side=tk.LEFT, padx=2)

        self._page_label = ttk.Label(toolbar, text='0 / 0')
        self._page_label.pack(side=tk.LEFT, padx=6)

        self._page_entry = ttk.Entry(toolbar, width=6)
        self._page_entry.bind('<Return>', self._cmd_go_page)
        self._page_entry.pack(side=tk.LEFT, padx=2)

        ttk.Separator(toolbar, orient=tk.VERTICAL).pack(side=tk.LEFT, fill=tk.Y, padx=6)

        ttk.Button(toolbar, text='Zoom In', command=self._cmd_zoom_in).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text='Zoom Out', command=self._cmd_zoom_out).pack(side=tk.LEFT, padx=2)
        self._zoom_label = ttk.Label(toolbar, text='100%')
        self._zoom_label.pack(side=tk.LEFT, padx=4)

        ttk.Button(toolbar, text='Fit Width', command=self._cmd_fit_width).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text='Fit Page', command=self._cmd_fit_page).pack(side=tk.LEFT, padx=2)
        ttk.Button(toolbar, text='100%', command=self._cmd_zoom_100).pack(side=tk.LEFT, padx=2)

        container = ttk.Frame(self)
        container.pack(side=tk.TOP, fill=tk.BOTH, expand=True)

        vbar = ttk.Scrollbar(container, orient=tk.VERTICAL)
        hbar = ttk.Scrollbar(container, orient=tk.HORIZONTAL)
        self._canvas = tk.Canvas(
            container,
            highlightthickness=0,
            xscrollcommand=hbar.set,
            yscrollcommand=vbar.set,
        )
        vbar.config(command=self._canvas.yview)
        hbar.config(command=self._canvas.xview)

        hbar.pack(side=tk.BOTTOM, fill=tk.X)
        vbar.pack(side=tk.RIGHT, fill=tk.Y)
        self._canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self._canvas.bind('<Configure>', self._on_canvas_resize)
        self._canvas.bind('<MouseWheel>', self._on_mousewheel)
        self._canvas.bind('<Control-MouseWheel>', self._on_ctrl_mousewheel)
        self._canvas.bind('<Button-4>', self._on_mousewheel_up)
        self._canvas.bind('<Button-5>', self._on_mousewheel_down)

        self._image_on_canvas = None

        self._status = ttk.Label(self, text='Ready', anchor=tk.W, padding=(8, 2))
        self._status.pack(side=tk.BOTTOM, fill=tk.X)

    def _bind_keys(self):
        self.bind('<Left>', lambda e: self._cmd_prev_page())
        self.bind('<Right>', lambda e: self._cmd_next_page())
        self.bind('<Up>', lambda e: self._scroll_up())
        self.bind('<Down>', lambda e: self._scroll_down())
        self.bind('<Prior>', lambda e: self._cmd_prev_page())
        self.bind('<Next>', lambda e: self._cmd_next_page())
        self.bind('<Home>', lambda e: self._cmd_first_page())
        self.bind('<End>', lambda e: self._cmd_last_page())
        self.bind('<Control-plus>', lambda e: self._cmd_zoom_in())
        self.bind('<Control-minus>', lambda e: self._cmd_zoom_out())
        self.bind('<Control-0>', lambda e: self._cmd_zoom_100())
        self.bind('<Control-w>', lambda e: self._cmd_close())
        self.bind('<Control-q>', lambda e: self.destroy())
        self.bind('<Escape>', lambda e: self._cmd_close())
        self._page_entry.bind('<Escape>', lambda e: self.focus_set())

    # ── Document management ───────────────────────────────────────

    def open_file(self, path: str):
        self._status.config(text=f'Loading: {path}')
        self.update_idletasks()
        try:
            doc = PDFDocument(path)
        except Exception as e:
            messagebox.showerror('Error', f'Cannot open:\n{path}\n\n{e}')
            self._status.config(text='Ready')
            return

        if self._doc:
            self._doc.close()

        self._doc = doc
        self._current_page = 0
        self._zoom = 1.0
        self._fit_mode = None
        self._page_images.clear()
        self._update_ui()
        self._render_page()
        self._status.config(text=f'Opened: {os.path.basename(path)}')

    def close_doc(self):
        if self._doc:
            self._doc.close()
            self._doc = None
        self._page_images.clear()
        self._canvas.delete('all')
        self._image_on_canvas = None
        self._update_ui()

    # ── Page rendering ────────────────────────────────────────────

    def _render_page(self):
        if not self._doc:
            return

        page_num = self._current_page
        zoom = self._zoom

        self._status.config(text=f'Rendering page {page_num + 1}…')
        self.update_idletasks()

        try:
            img = self._doc.get_page_pixmap(page_num, zoom)
        except Exception as e:
            messagebox.showerror('Error', f'Failed to render page:\n{e}')
            self._status.config(text='Ready')
            return

        photo = ImageTk.PhotoImage(img)
        self._page_images[page_num] = photo

        self._canvas.delete('all')
        self._image_on_canvas = self._canvas.create_image(0, 0, anchor=tk.NW, image=photo)
        self._canvas.config(scrollregion=(0, 0, photo.width(), photo.height()))

        self._update_ui()
        self._status.config(
            text=f'Page {page_num + 1} / {self._doc.page_count}  |  Zoom: {int(round(zoom * 100))}%'
        )

    def _update_ui(self):
        total = self._doc.page_count if self._doc else 0
        curr = self._current_page + 1 if self._doc else 0
        self._page_label.config(text=f'{curr} / {total}')
        if self._doc:
            self._zoom_label.config(text=f'{int(round(self._zoom * 100))}%')
        else:
            self._zoom_label.config(text='')

    def _get_viewport_size(self):
        w = self._canvas.winfo_width()
        h = self._canvas.winfo_height()
        return max(100, w), max(100, h)

    # ── Event handlers ────────────────────────────────────────────

    def _on_canvas_resize(self, event):
        if self._fit_mode == 'width' and self._doc:
            self._zoom_to_fit_width()
            self._render_page()
        elif self._fit_mode == 'page' and self._doc:
            self._zoom_to_fit_page()
            self._render_page()

    def _on_mousewheel(self, event):
        self._canvas.yview_scroll(int(-event.delta / 60), 'units')

    def _on_ctrl_mousewheel(self, event):
        if event.delta > 0:
            self._cmd_zoom_in()
        else:
            self._cmd_zoom_out()

    def _on_mousewheel_up(self, _e):
        self._canvas.yview_scroll(-3, 'units')

    def _on_mousewheel_down(self, _e):
        self._canvas.yview_scroll(3, 'units')

    def _scroll_up(self):
        self._canvas.yview_scroll(-1, 'pages')

    def _scroll_down(self):
        self._canvas.yview_scroll(1, 'pages')

    # ── Zoom calculations ─────────────────────────────────────────

    def _get_page_dimensions(self):
        return self._doc.get_page_size(self._current_page)

    def _zoom_to(self, zoom: float):
        self._fit_mode = None
        self._zoom = max(self.MIN_ZOOM, min(self.MAX_ZOOM, zoom))

    def _zoom_to_fit_width(self):
        self._fit_mode = 'width'
        pw, _ph = self._get_page_dimensions()
        vw, _vh = self._get_viewport_size()
        self._zoom = max(self.MIN_ZOOM, min(self.MAX_ZOOM, (vw - 4) / pw))

    def _zoom_to_fit_page(self):
        self._fit_mode = 'page'
        pw, ph = self._get_page_dimensions()
        vw, vh = self._get_viewport_size()
        zoom_x = (vw - 4) / pw
        zoom_y = (vh - 4) / ph
        self._zoom = max(self.MIN_ZOOM, min(self.MAX_ZOOM, min(zoom_x, zoom_y)))

    # ── Commands ──────────────────────────────────────────────────

    def _cmd_open(self):
        path = filedialog.askopenfilename(
            title='Open PDF',
            filetypes=[('PDF files', '*.pdf'), ('All files', '*.*')],
        )
        if path:
            self.open_file(path)

    def _cmd_prev_page(self):
        if not self._doc:
            return
        if self._current_page > 0:
            self._current_page -= 1
            self._page_images.clear()
            self._render_page()

    def _cmd_next_page(self):
        if not self._doc:
            return
        if self._current_page < self._doc.page_count - 1:
            self._current_page += 1
            self._page_images.clear()
            self._render_page()

    def _cmd_go_page(self, event=None):
        if not self._doc:
            return
        try:
            n = int(self._page_entry.get()) - 1
        except ValueError:
            return
        if 0 <= n < self._doc.page_count:
            self._current_page = n
            self._page_images.clear()
            self._render_page()

    def _cmd_first_page(self):
        if not self._doc:
            return
        self._current_page = 0
        self._page_images.clear()
        self._render_page()

    def _cmd_last_page(self):
        if not self._doc:
            return
        self._current_page = self._doc.page_count - 1
        self._page_images.clear()
        self._render_page()

    def _cmd_zoom_in(self):
        if not self._doc:
            return
        self._zoom_to(self._zoom * self.ZOOM_STEP)
        self._page_images.clear()
        self._render_page()

    def _cmd_zoom_out(self):
        if not self._doc:
            return
        self._zoom_to(self._zoom / self.ZOOM_STEP)
        self._page_images.clear()
        self._render_page()

    def _cmd_zoom_100(self):
        if not self._doc:
            return
        self._zoom_to(1.0)
        self._page_images.clear()
        self._render_page()

    def _cmd_fit_width(self):
        if not self._doc:
            return
        self._zoom_to_fit_width()
        self._page_images.clear()
        self._render_page()

    def _cmd_fit_page(self):
        if not self._doc:
            return
        self._zoom_to_fit_page()
        self._page_images.clear()
        self._render_page()

    def _cmd_close(self):
        self.close_doc()


def main():
    app = PDFViewer()
    app.mainloop()


if __name__ == '__main__':
    main()
