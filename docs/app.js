
// ===============================
// NAV LOAD (ARRAY-BASED JSON)
// ===============================
async function loadNav() {
  try {
    const res = await fetch('nav.json');
    const nav = await res.json();

    const sidebar = document.getElementById('sidebar');
    sidebar.innerHTML = "";

    const iconMap = {
      "documentation": "images/icon-doc-cmds.svg"
    };

    nav.forEach(section => {

      const sectionDiv = document.createElement('div');
      sectionDiv.className = 'section';

      const title = document.createElement('div');
      title.className = 'section-title';

      const key = section.title?.toLowerCase()?.trim();
      const icon = iconMap[key];

      title.innerHTML = `
        ${icon ? `
          <span class="section-icon">
            <img src="${icon}" alt="">
          </span>
        ` : ''}
        ${section.title.toUpperCase()}
      `;

      const submenu = document.createElement('div');
      submenu.className = 'submenu';

      title.onclick = () => {
        const isOpen = submenu.classList.contains('open');

        if (isOpen) {
          submenu.classList.remove('open');
          sectionDiv.classList.remove('open');
        } else {
          document.querySelectorAll('.submenu').forEach(s => s.classList.remove('open'));
          document.querySelectorAll('.section').forEach(s => s.classList.remove('open'));

          submenu.classList.add('open');
          sectionDiv.classList.add('open');
        }
      };

      section.sections.forEach(sub => {

        const subDiv = document.createElement('div');
        subDiv.className = 'sub-section';

        const subTitle = document.createElement('div');
        subTitle.className = 'sub-section-title';

        const subIconMap = {
          "installation guide":   "images/icon-gear.svg",
          "dashboard & health":   "images/icon-radar.svg",
          "active directory":     "images/icon-user.svg",
          "dns":                  "images/icon-dns.svg",
          "dhcp":                 "images/icon-dhcp.svg",
          "sites & services":     "images/icon-sites-services.svg",
          "policy":               "images/icon-group-policy.svg",
          "system administration":"images/icon-toolbox.svg"
        };

        const subKey = sub.title?.toLowerCase()?.replace(/\s+/g, ' ')?.trim();
        const subIcon = subIconMap[subKey];

        subTitle.innerHTML = `
          ${subIcon ? `
            <span class="section-icon">
              <img src="${subIcon}" class="icon-${subKey.replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}" alt="">
            </span>
          ` : ''}
          <span>${sub.title}</span>
        `;

        const subMenu = document.createElement('div');
        subMenu.className = 'submenu';

        subTitle.onclick = () => {
          subMenu.classList.toggle('open');
          subDiv.classList.toggle('open');
        };

        sub.items.forEach(itemData => {
          const item = document.createElement('div');
          item.className = 'nav-item';
          item.textContent = itemData.name;

          item.onclick = () => {
            document.querySelectorAll('.nav-item').forEach(i => i.classList.remove('active'));
            item.classList.add('active');
            loadDoc(itemData.file);
          };

          subMenu.appendChild(item);
        });

        subDiv.appendChild(subTitle);
        subDiv.appendChild(subMenu);
        submenu.appendChild(subDiv);
      });

      sectionDiv.appendChild(title);
      sectionDiv.appendChild(submenu);
      sidebar.appendChild(sectionDiv);

    });

  } catch (err) {
    console.error("Nav load failed:", err);
  }
}

// ===============================
// SEARCH FILTER
// ===============================
function initSearch() {
  const search = document.getElementById('docSearch');
  if (!search) return;

  search.addEventListener('input', () => {
    const term = search.value.toLowerCase().trim();
    const sections = document.querySelectorAll('.sub-section');

    sections.forEach(section => {
      const title = section.querySelector('.sub-section-title span')?.textContent?.toLowerCase() || '';
      const items = section.querySelectorAll('.nav-item');
      let matched = false;

      items.forEach(item => {
        const text = item.textContent.toLowerCase();
        const isMatch = text.includes(term) || title.includes(term);
        item.style.display = isMatch || term === '' ? 'flex' : 'none';
        if (isMatch) matched = true;
      });

      section.style.display = matched || title.includes(term) || term === '' ? '' : 'none';

      const submenu = section.querySelector('.submenu');
      if (term !== '' && matched) {
        submenu.classList.add('open');
        section.classList.add('open');
      }
    });
  });

  search.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') {
      search.value = '';
      search.dispatchEvent(new Event('input'));
      search.blur();
    }
  });

  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
      e.preventDefault();
      search.focus();
      search.select();
    }
  });
}

// ===============================
// BREADCRUMB HELPER
// ===============================
function getBreadcrumb(nav, file) {
  let result = null;
  nav.forEach(section => {
    section.sections?.forEach(sub => {
      sub.items?.forEach(item => {
        if (item.file === file) {
          result = { section: section.title, sub: sub.title, page: item.name };
        }
      });
    });
  });
  return result;
}

// ===============================
// LOAD DOC
// ===============================
async function loadDoc(file) {
  try {
    const res = await fetch(file);
    const content = await res.text();
    const contentDiv = document.getElementById('content');

    if (file.endsWith('.md') && typeof marked !== "undefined") {
      contentDiv.innerHTML = marked.parse(content);

      contentDiv.querySelectorAll('a[href^="http"]').forEach(link => {
        link.setAttribute('target', '_blank');
        link.setAttribute('rel', 'noopener noreferrer');
      });

      contentDiv.querySelectorAll('a[href$=".md"]').forEach(link => {
        link.addEventListener('click', (e) => {
          e.preventDefault();
          loadDoc(link.getAttribute('href'));
        });
      });

    } else {
      contentDiv.innerHTML = content;
    }

    const navRes = await fetch('nav.json');
    const nav = await navRes.json();

    let pages = [];
    nav.forEach(section => {
      section.sections?.forEach(sub => {
        sub.items?.forEach(item => {
          if (item.file === file) pages = sub.items;
        });
      });
    });

    const currentIndex = pages.findIndex(p => p.file === file);
    const prev = pages[currentIndex - 1];
    const next = pages[currentIndex + 1];

    const crumbData = getBreadcrumb(nav, file);

    const navFooter = document.createElement('div');
    navFooter.className = 'doc-nav';

    navFooter.innerHTML = `
      <div class="doc-nav-inner">
        ${prev ? `<div class="doc-prev" onclick="loadDoc('${prev.file}')">← ${prev.name}</div>` : `<div></div>`}
        ${crumbData ? `
          <div class="doc-breadcrumb">
            ${crumbData.section}
            <span>›</span>
            ${crumbData.sub}
            <span>›</span>
            <strong>${crumbData.page}</strong>
          </div>
        ` : ``}
        ${next ? `<div class="doc-next" onclick="loadDoc('${next.file}')">${next.name} →</div>` : ``}
      </div>
    `;

    contentDiv.appendChild(navFooter);
    window.scrollTo(0, 0);
    document.getElementById('content').scrollTo(0, 0);

  } catch (err) {
    document.getElementById('content').innerHTML = "<h2>Failed to load document</h2>";
    console.error("Doc load failed:", err);
  }
}

// ===============================
// DARK MODE TOGGLE
// ===============================
function initThemeToggle() {
  const btn = document.querySelector('.theme-toggle');
  if (!btn) return;

  const setIcon = (isDark) => {
    btn.innerHTML = `<img src="${isDark ? 'images/icon-sun.svg' : 'images/icon-moon.svg'}" alt="">`;
  };

  const saved = localStorage.getItem('rads-web-docs-theme');

  if (saved === 'dark') {
    document.body.classList.add('dark');
    setIcon(true);
  } else {
    setIcon(false);
  }

  btn.addEventListener('click', () => {
    document.body.classList.toggle('dark');
    const isDark = document.body.classList.contains('dark');
    localStorage.setItem('rads-web-docs-theme', isDark ? 'dark' : 'light');
    setIcon(isDark);
  });
}

// ===============================
// INIT
// ===============================
document.addEventListener('DOMContentLoaded', async () => {
  await loadNav();
  initThemeToggle();
  initSearch();
});

// ===============================
// HOME BUTTON
// ===============================
function goHome() {
  location.reload();
}
