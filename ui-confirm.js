/* Единый модал подтверждения опасных действий — Beta 66.
   Заменяет браузерный confirm(). Доступен: фокус удерживается в окне,
   Esc — отмена, Enter — подтвердить, по умолчанию фокус на безопасной кнопке.
   Использование:  if(!(await uiConfirm({title, message, confirmText, cancelText, danger}))) return; */
(function(){
  if (window.uiConfirm) return;
  var LBL = {
    ru:{confirm:"Подтвердить",cancel:"Отмена",title:"Подтверждение"},
    kk:{confirm:"Растау",cancel:"Болдырмау",title:"Растау"},
    en:{confirm:"Confirm",cancel:"Cancel",title:"Please confirm"},
    ar:{confirm:"تأكيد",cancel:"إلغاء",title:"يرجى التأكيد"}
  };
  function lang(){
    var l = window.currentLang || document.documentElement.lang || "ru";
    return LBL[l] ? l : "ru";
  }
  function build(){
    var dlg = document.createElement("dialog");
    dlg.id = "uiConfirmDialog";
    dlg.setAttribute("role","alertdialog");
    dlg.setAttribute("aria-modal","true");
    dlg.style.cssText = "max-width:440px;width:calc(100vw - 32px);border:0;border-radius:16px;padding:0;"
      + "box-shadow:0 24px 60px rgba(15,32,24,.28);color:#1f2a24;background:#fff;"
      + "font-family:inherit;";
    dlg.innerHTML =
      '<div style="padding:22px 22px 8px">'
      + '<h2 id="uiConfirmTitle" style="margin:0 0 8px;font-size:1.18rem;line-height:1.3;font-weight:800"></h2>'
      + '<p id="uiConfirmMsg" style="margin:0;font-size:1rem;line-height:1.5;color:#3a473f;white-space:pre-line"></p>'
      + '</div>'
      + '<div style="display:flex;gap:10px;justify-content:flex-end;flex-wrap:wrap;padding:16px 22px 20px">'
      + '<button type="button" id="uiConfirmCancel" style="padding:11px 18px;border:1px solid #cdd8d0;border-radius:10px;'
      + 'background:#f3f7f4;color:#1f2a24;font-weight:700;font-size:.97rem;cursor:pointer">Отмена</button>'
      + '<button type="button" id="uiConfirmOk" style="padding:11px 18px;border:0;border-radius:10px;'
      + 'background:var(--blue,#1f5d4c);color:#fff;font-weight:750;font-size:.97rem;cursor:pointer">Подтвердить</button>'
      + '</div>';
    document.body.appendChild(dlg);
    return dlg;
  }
  window.uiConfirm = function(opts){
    opts = opts || {};
    var L = LBL[lang()];
    var dlg = document.getElementById("uiConfirmDialog") || build();
    dlg.dir = document.documentElement.dir || "ltr";
    var titleEl = dlg.querySelector("#uiConfirmTitle"),
        msgEl = dlg.querySelector("#uiConfirmMsg"),
        okBtn = dlg.querySelector("#uiConfirmOk"),
        cancelBtn = dlg.querySelector("#uiConfirmCancel");
    titleEl.textContent = opts.title || L.title;
    msgEl.textContent = opts.message || "";
    msgEl.style.display = opts.message ? "" : "none";
    okBtn.textContent = opts.confirmText || L.confirm;
    cancelBtn.textContent = opts.cancelText || L.cancel;
    var danger = opts.danger !== false; // по умолчанию опасное действие
    okBtn.style.background = danger ? "#c0392b" : "var(--blue,#1f5d4c)";
    return new Promise(function(resolve){
      var done = false;
      function finish(val){
        if (done) return; done = true;
        dlg.removeEventListener("keydown", onKey, true);
        okBtn.onclick = cancelBtn.onclick = null;
        try { dlg.close(); } catch(e){}
        resolve(val);
      }
      function onKey(e){
        if (e.key === "Enter"){ e.preventDefault(); finish(true); }
        else if (e.key === "Escape"){ e.preventDefault(); finish(false); }
        else if (e.key === "Tab"){
          var f = [cancelBtn, okBtn], i = f.indexOf(document.activeElement);
          e.preventDefault();
          f[(i + (e.shiftKey ? f.length - 1 : 1)) % f.length].focus();
        }
      }
      okBtn.onclick = function(){ finish(true); };
      cancelBtn.onclick = function(){ finish(false); };
      dlg.addEventListener("keydown", onKey, true);
      dlg.addEventListener("cancel", function(ev){ ev.preventDefault(); finish(false); }, { once:true });
      if (typeof dlg.showModal === "function") dlg.showModal(); else dlg.setAttribute("open","");
      // безопасный фокус: на «Отмена» для опасных действий
      (danger ? cancelBtn : okBtn).focus();
    });
  };
})();
