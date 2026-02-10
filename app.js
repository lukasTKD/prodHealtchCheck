let serverData = null;
let currentGroup = 'DCI';

async function loadData() {
    try {
        const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
        serverData = await response.json();
        updateUI();
    } catch (error) {
        document.getElementById('serverGrid').innerHTML =
            '<div class="error-message">Blad ladowania danych: ' + error.message + '</div>';
    }
}

function switchTab(group) {
    currentGroup = group;
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelector('.tab[data-group="' + group + '"]').classList.add('active');
    document.getElementById('searchInput').value = '';
    document.getElementById('serverGrid').innerHTML = '<div class="loading">Ladowanie danych...</div>';
    loadData();
}

function getProgressClass(percent) {
    if (percent >= 90) return 'red';
    if (percent >= 70) return 'yellow';
    return 'green';
}

function getServiceStateClass(state) {
    if (!state) return '';
    const s = state.toLowerCase();
    if (s === 'running') return 'running';
    if (s === 'stopped') return 'stopped';
    return '';
}

function updateUI() {
    if (!serverData) return;
    document.getElementById('lastUpdate').textContent = serverData.LastUpdate;
    document.getElementById('duration').textContent = serverData.CollectionDuration;
    document.getElementById('totalServers').textContent = serverData.TotalServers;
    document.getElementById('successServers').textContent = serverData.SuccessCount;
    document.getElementById('failedServers').textContent = serverData.FailedCount;

    let criticalCount = 0;
    serverData.Servers.forEach(s => {
        if (s.CPU >= 90 || (s.RAM && s.RAM.PercentUsed >= 90)) criticalCount++;
    });
    document.getElementById('criticalServers').textContent = criticalCount;
    renderServers(serverData.Servers);
}

function renderServers(servers) {
    const grid = document.getElementById('serverGrid');
    if (!servers || servers.length === 0) {
        grid.innerHTML = '<div class="loading">Brak danych</div>';
        return;
    }

    grid.innerHTML = servers.map(server => {
        const hasError = server.Error;
        const isCritical = server.CPU >= 90 || (server.RAM && server.RAM.PercentUsed >= 90);
        const cardClass = hasError ? 'error' : (isCritical ? 'warning' : '');

        if (hasError) {
            return `
                <div class="server-card error" data-server="${server.ServerName}">
                    <div class="server-name">
                        ${server.ServerName}
                        <span class="time">${server.CollectedAt || ''}</span>
                    </div>
                    <div class="error-message">${server.Error}</div>
                </div>
            `;
        }

        const cpuPercent = server.CPU || 0;
        const ramPercent = server.RAM?.PercentUsed || 0;

        return `
            <div class="server-card ${cardClass}" data-server="${server.ServerName}">
                <div class="server-name">
                    ${server.ServerName}
                    <span class="time">${server.CollectedAt || ''}</span>
                </div>

                <div class="metrics-grid">
                    <div class="metric">
                        <div class="metric-label">CPU</div>
                        <div class="metric-value">${cpuPercent}%</div>
                        <div class="progress-bar">
                            <div class="progress-fill ${getProgressClass(cpuPercent)}" style="width: ${cpuPercent}%"></div>
                        </div>
                    </div>
                    <div class="metric">
                        <div class="metric-label">RAM</div>
                        <div class="metric-value">${ramPercent}% (${server.RAM?.UsedGB || 0}/${server.RAM?.TotalGB || 0} GB)</div>
                        <div class="progress-bar">
                            <div class="progress-fill ${getProgressClass(ramPercent)}" style="width: ${ramPercent}%"></div>
                        </div>
                    </div>
                </div>

                <div class="section">
                    <div class="section-title">Dyski</div>
                    <div class="disk-list">
                        ${(server.Disks || []).map(d => `
                            <div class="disk-item">
                                <div class="drive">${d.Drive}</div>
                                <div class="space">${d.FreeGB}/${d.TotalGB} GB wolne</div>
                                <div class="progress-bar">
                                    <div class="progress-fill ${getProgressClass(100 - d.PercentFree)}" style="width: ${100 - d.PercentFree}%"></div>
                                </div>
                            </div>
                        `).join('')}
                    </div>
                </div>

                <div class="metrics-grid" style="margin-top: 12px;">
                    <div class="section">
                        <div class="section-title collapsible" onclick="toggleSection(this)">Top 3 CPU</div>
                        <div class="collapsible-content">
                            ${(server.TopCPUServices || []).map(p => `
                                <div class="top-process">
                                    <span>${p.Name}</span>
                                    <span>${p.CPUPercent}%</span>
                                </div>
                            `).join('')}
                        </div>
                    </div>
                    <div class="section">
                        <div class="section-title collapsible" onclick="toggleSection(this)">Top 3 RAM</div>
                        <div class="collapsible-content">
                            ${(server.TopRAMServices || []).map(p => `
                                <div class="top-process">
                                    <span>${p.Name}</span>
                                    <span>${p.MemoryMB} MB</span>
                                </div>
                            `).join('')}
                        </div>
                    </div>
                </div>

                <div class="section">
                    <div class="section-title collapsible" onclick="toggleSection(this)">
                        Serwisy D:\\ (${(server.DServices || []).length})
                    </div>
                    <div class="collapsible-content">
                        <div class="service-list">
                            ${(server.DServices || []).map(s => `
                                <span class="service-badge ${getServiceStateClass(s.State)}" title="${s.DisplayName}">
                                    ${s.Name}: ${s.State}
                                </span>
                            `).join('')}
                            ${(server.DServices || []).length === 0 ? '<span style="color:#888">Brak</span>' : ''}
                        </div>
                    </div>
                </div>

                <div class="metrics-grid" style="margin-top: 12px;">
                    <div class="section">
                        <div class="section-title">Trellix</div>
                        <div class="service-list">
                            ${(server.TrellixStatus || []).map(t => `
                                <span class="service-badge ${getServiceStateClass(t.State)}" title="${t.Name}">
                                    ${t.State}
                                </span>
                            `).join('')}
                        </div>
                    </div>
                    <div class="section">
                        <div class="section-title">Firewall</div>
                        <div class="firewall-list">
                            <div>Domain: <span class="status-badge ${server.Firewall?.Domain ? 'status-on' : 'status-off'}">${server.Firewall?.Domain ? 'ON' : 'OFF'}</span></div>
                            <div>Private: <span class="status-badge ${server.Firewall?.Private ? 'status-on' : 'status-off'}">${server.Firewall?.Private ? 'ON' : 'OFF'}</span></div>
                            <div>Public: <span class="status-badge ${server.Firewall?.Public ? 'status-on' : 'status-off'}">${server.Firewall?.Public ? 'ON' : 'OFF'}</span></div>
                        </div>
                    </div>
                </div>
            </div>
        `;
    }).join('');
}

function toggleSection(element) {
    element.classList.toggle('collapsed');
    element.nextElementSibling.classList.toggle('hidden');
}

function filterServers() {
    const search = document.getElementById('searchInput').value.toLowerCase();
    document.querySelectorAll('.server-card').forEach(card => {
        card.style.display = card.dataset.server.toLowerCase().includes(search) ? 'block' : 'none';
    });
}

let criticalFilterActive = false;
function filterCritical() {
    criticalFilterActive = !criticalFilterActive;
    document.querySelector('.stat-card.warning').classList.toggle('active', criticalFilterActive);

    if (criticalFilterActive) {
        document.querySelectorAll('.server-card').forEach(card => {
            card.style.display = card.classList.contains('warning') ? 'block' : 'none';
        });
    } else {
        document.querySelectorAll('.server-card').forEach(card => {
            card.style.display = 'block';
        });
        document.getElementById('searchInput').value = '';
    }
}

async function refreshData() {
    const modal = document.getElementById('refreshModal');
    const modalText = modal.querySelector('.modal-text');
    modal.classList.add('show');

    const oldUpdate = serverData?.LastUpdate;

    try {
        const refreshResponse = await fetch('api.aspx?action=refresh&t=' + Date.now());
        const refreshResult = await refreshResponse.json();

        if (refreshResult.status === 'running') {
            modalText.textContent = 'Update juz trwa - czekam na zakonczenie...';
        } else {
            modalText.textContent = 'Odswiezanie danych...';
        }

        let attempts = 0;
        const maxAttempts = 120;

        const checkUpdate = async () => {
            attempts++;
            const statusText = refreshResult.status === 'running'
                ? 'Update w trakcie - czekam... (' + attempts + 's)'
                : 'Odswiezanie danych... (' + attempts + 's)';
            modalText.textContent = statusText;

            try {
                const response = await fetch('api.aspx?group=' + currentGroup + '&t=' + Date.now());
                const data = await response.json();

                if (data.LastUpdate && data.LastUpdate !== oldUpdate) {
                    location.reload();
                    return;
                }
            } catch (e) {}

            if (attempts < maxAttempts) {
                setTimeout(checkUpdate, 1000);
            } else {
                modalText.textContent = 'Timeout - odswiezam strone...';
                setTimeout(() => location.reload(), 1000);
            }
        };

        setTimeout(checkUpdate, 2000);

    } catch (error) {
        modalText.textContent = 'Blad: ' + error.message;
        setTimeout(() => modal.classList.remove('show'), 3000);
    }
}

loadData();
setInterval(loadData, 300000);
